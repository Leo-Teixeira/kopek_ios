import Foundation

enum IncomeType: String {
    case SALARY
    case SELFEMPLOYED
    case THIRDPARTY
    case OTHER
}

enum BucketKind: String, CaseIterable {
    case FIXED
    case LIFESTYLE
    case SAVING
    case ENVELOPE

    var cutOrder: BucketKind {
        switch self {
        case .ENVELOPE: return .ENVELOPE
        case .SAVING: return .SAVING
        case .LIFESTYLE: return .LIFESTYLE
        case .FIXED: return .SAVING
        }
    }
}

enum ChargeFrequency: String {
    case MONTHLY
    case QUATERLY
    case ANNUALLY

    var occurrencesPerYear: Int {
        switch self {
        case .MONTHLY: return 12
        case .QUATERLY: return 4
        case .ANNUALLY: return 1
        }
    }
}

struct IncomeSummary: Equatable {
    let gross: Int
    let selfEmployed: Int
    let ursaff: Int
    let net: Int
}

struct RuleTotal: Equatable {
    let percents: Double
    let fixed: Double
    let fixedPercent: Double?
    let total: Double?
}

struct BucketInput: Equatable {
    let id: String
    let name: String
    let kind: BucketKind
    let percent: Double
    let fixedAmount: Double?
}

struct BucketResult: Equatable {
    var input: BucketInput
    var base: Int
    var fromSurplus: Int
    var adjustment: Int
    var amount: Int
}

struct ExpenseComparison: Equatable {
    let kind: BucketKind
    let objective: Int
    let actual: Int
    let delta: Int
}

struct MonthAllocation: Equatable {
    let available: Double
    let reference: Double
    let base: Double
    let surplus: Double
    let fixedCharges: Double
    let fixedMargin: Double
    let shortFall: Double
    let unallocated: Double
    let buckets: [BucketResult]
}

func monthlyEquivalent(amount: Int, frequency: ChargeFrequency) -> Double {
    return round(Double(amount * frequency.occurrencesPerYear) / 12)
}

struct Charges: Equatable {
    let id: String
    let label: String
    let amount: Int
    let frequency: ChargeFrequency
    let active: Bool
}

struct Expense: Equatable {
    let userId: String
    let month: String
    let label: String
    let amount: Double
    let kind: String
    let category: String
    let recurringChargeId: String
}

func expensesFromCharges(charges: [Charges], userId: String, month: String) -> [Expense] {
    return charges.filter({ charge in charge.active }).map({charge in Expense(
        userId: userId,
        month: month,
        label: charge.label,
        amount: Double(charge.amount),
        kind: "FIXED",
        category: "FIXED",
        recurringChargeId: charge.id
    )})
}

struct Incomes: Equatable {
    let type: IncomeType
    let amount: Int
}

func summarizeIncomes(incomes: [Incomes], ursaffRate: Int) -> IncomeSummary {
    var gross = 0
    var selfEmployed = 0
    for income in incomes {
        gross += income.amount
        if (income.type == IncomeType.SELFEMPLOYED) {
            selfEmployed += income.amount
        }
    }
    let ursaff = round(Double(selfEmployed * ursaffRate) / 100)
    return IncomeSummary(gross: gross, selfEmployed: selfEmployed, ursaff: Int(ursaff), net: gross - Int(ursaff))
}


func ruleTotal(buckets: [BucketInput], income: Double) -> RuleTotal {
    func roundValue(number: Double) -> Double {
        return round(number * 10) / 10
    }
    let percents = roundValue(number: buckets.filter({ bucket in bucket.fixedAmount == nil }).reduce(0.0, { $0 + $1.percent}))
    let fixed = buckets.reduce(0.0, {$0 + ($1.fixedAmount ?? 0)})
    let fixedPercents = fixed == 0 ? 0 : income > 0 ? roundValue(number: (fixed * 100) / income) : nil
    return RuleTotal(
        percents: percents,
        fixed: fixed,
        fixedPercent: fixedPercents,
        total: percents + fixed
    )
}

func effectiveShares(buckets: [BucketInput], income: Double) -> [String: Double] {
    let fixedTotal = buckets.reduce(0.0, {$0 + ($1.fixedAmount ?? 0)})
    let weights = buckets.reduce(0.0, {$0 + ($1 == nil ? $1.percent : 0) })
    let fixedShare = income > 0 ? min((fixedTotal * 100) / income, 100) : 0.0
    return buckets.reduce(into: [String: Double]()) { result, bucket in

        let amount: Double

        if let fixedAmount = bucket.fixedAmount {
            amount = fixedTotal > 0
                ? (fixedShare * fixedAmount) / fixedTotal
                : 0

        } else {
            amount = weights > 0
                ? ((100 - fixedShare) * bucket.percent) / weights
                : 0
        }

        result[bucket.id] = amount
    }
}

func minIncomeForFixedCharges(fixedCharges: Double, fixedPct: Double) -> Int {
    return Int(fixedPct > 0 ? ceil((fixedCharges * 100) / fixedPct) : 0.0)
}

func referenceIncome(pastNets: [Int]) -> Int {
    let months = pastNets.filter({ month in month > 0})
    if (months.count == 0){
        return 0
    }
    return Int(round(months.reduce(0.0, { Double((Int($0) + $1) / months.count) })))
}

struct Expenses: Equatable {
    let kind: BucketKind
    let amount: Int
}

func summarizeExpenses(
    expenses: [Expense],
    buckets: [BucketResult]
) -> [ExpenseComparison] {

    let kinds = BucketKind.allCases

    return kinds
        .map { kind in

            let objective = buckets
                .filter { $0.input.kind == kind }
                .reduce(0) { $0 + $1.amount }

            let actual = expenses
                .filter { $0.kind == kind.rawValue }
                .reduce(0.0) { $0 + $1.amount }

            return ExpenseComparison(
                kind: kind,
                objective: objective,
                actual: Int(actual),
                delta: objective - Int(actual)
            )
        }
        .filter { $0.objective > 0 || $0.actual > 0 }
}

private func spread(total: Double, weights: [Double]) -> [Double] {
    if (total <= 0 || weights.count == 0) {
        return weights.map({_ in 0})
    }
    let sum = weights.reduce(0.0, {$0 + $1})
    if (sum <= 0) {
        return weights.map({_ in 0})
    }
    var shares = weights.map({ weight in floor(total * weight) / sum})
    var rest = total - shares.reduce(0.0, { $0 + $1 })
    var idx = 0
    while (rest > 0) {
        shares[idx] += 1.0
        rest -= 1.0
        idx = (idx + 1) % shares.count
    }
    return shares
}

struct AllocateMonthInput {
    let net: Double
    let reference: Double
    let fixedCharges: Double
    let buckets: [BucketInput]
    let surplusSavingsPct: Double
}

private func createBucketResults(
    _ buckets: [BucketInput]
) -> [BucketResult] {

    return buckets.map { bucket in
        BucketResult(
            input: bucket,
            base: 0,
            fromSurplus: 0,
            adjustment: 0,
            amount: 0
        )
    }
}

private func allocateBase(
    results: [BucketResult],
    base: Double
) -> [BucketResult] {

    var results = results

    let fixedIndices = results.indices.filter {
        results[$0].input.fixedAmount != nil
    }

    let flexibleIndices = results.indices.filter {
        results[$0].input.fixedAmount == nil
    }

    let totalFixedAmount = fixedIndices.reduce(0.0) {
        $0 + (results[$1].input.fixedAmount ?? 0)
    }

    if totalFixedAmount > base {

        let shares = spread(
            total: base,
            weights: fixedIndices.map {
                results[$0].input.fixedAmount ?? 0
            }
        )

        for (idx, index) in fixedIndices.enumerated() {
            results[index].base = Int(shares[idx])
        }

        for index in flexibleIndices {
            results[index].base = 0
        }

    } else {

        for index in fixedIndices {
            results[index].base = Int(
                results[index].input.fixedAmount ?? 0
            )
        }

        let shares = spread(
            total: base - totalFixedAmount,
            weights: flexibleIndices.map {
                results[$0].input.percent
            }
        )

        for (idx, index) in flexibleIndices.enumerated() {
            results[index].base = Int(shares[idx])
        }
    }

    return results
}

private func allocateSurplus(
    results: [BucketResult],
    surplus: Double,
    surplusSavingsPct: Double
) -> [BucketResult] {

    var results = results

    guard surplus > 0 else { return results }

    let flexibleIndices = results.indices.filter {
        results[$0].input.fixedAmount == nil
    }

    let savers = flexibleIndices.filter {
        (results[$0].input.kind == .SAVING ||
         results[$0].input.kind == .ENVELOPE)
        && results[$0].input.percent > 0
    }

    let toSavers = !savers.isEmpty
        ? (surplus * surplusSavingsPct / 100).rounded()
        : 0

    let saverShares = spread(
        total: toSavers,
        weights: savers.map {
            results[$0].input.percent
        }
    )

    for (idx, index) in savers.enumerated() {
        results[index].fromSurplus += Int(saverShares[idx])
    }

    let remainingSurplus = surplus - toSavers

    let flexibleShares = spread(
        total: remainingSurplus,
        weights: flexibleIndices.map {
            results[$0].input.percent
        }
    )

    for (idx, index) in flexibleIndices.enumerated() {
        results[index].fromSurplus += Int(flexibleShares[idx])
    }

    return results
}

private func coverFixedCharges(
    results: [BucketResult],
    fixedCharges: Double,
    cutOrder: [BucketKind]
) -> (shortfall: Double, fixedMargin: Double) {

    var results = results

    let fixed = results.indices.filter {
        results[$0].input.kind == .FIXED
    }

    let fixedBudget = fixed.reduce(0.0) {
        $0 + Double(results[$1].amount)
    }

    var gap = !fixed.isEmpty
        ? fixedCharges - fixedBudget
        : fixedCharges

    var covered = 0.0

    if gap > 0 && !fixed.isEmpty {

        for kind in cutOrder {

            if gap <= 0 {
                break
            }

            let group = results.indices.filter {
                results[$0].input.kind == kind
                && results[$0].amount > 0
            }

            let pool = group.reduce(0.0) {
                $0 + Double(results[$1].amount)
            }

            let take = min(pool, gap)

            let shares = spread(
                total: take,
                weights: group.map {
                    Double(results[$0].amount)
                }
            )

            for (idx, index) in group.enumerated() {
                results[index].adjustment -= Int(shares[idx])
                results[index].amount -= Int(shares[idx])
            }

            gap -= take
            covered += take
        }

        let fixedShares = spread(
            total: covered,
            weights: fixed.map {
                results[$0].input.percent != 0
                    ? results[$0].input.percent
                    : 1
            }
        )

        for (idx, index) in fixed.enumerated() {
            results[index].adjustment += Int(fixedShares[idx])
            results[index].amount += Int(fixedShares[idx])
        }
    }

    let shortfall = max(gap, 0)

    let fixedAfter = fixed.reduce(0.0) {
        $0 + Double(results[$1].amount)
    }

    let fixedMargin = !fixed.isEmpty
        ? max(fixedAfter - fixedCharges, 0)
        : 0

    return (shortfall, fixedMargin)
}

func allocateMonth(
    input: AllocateMonthInput,
    cutOrder: [BucketKind]
) -> MonthAllocation {

    let available = max(input.net, 0)

    let base = input.reference > 0 && available > input.reference
        ? input.reference
        : available

    let surplus = available - base

    var res = createBucketResults(input.buckets)

    // 1. Répartition de la base.
    allocateBase(results: res, base: base)

    // 2. Répartition du surplus.
    allocateSurplus(
        results: res,
        surplus: surplus,
        surplusSavingsPct: input.surplusSavingsPct
    )

    // 3. Calcul des montants avant ajustement.
    for index in res.indices {
        res[index].amount = res[index].base + res[index].fromSurplus
    }

    // 4. Couverture des charges fixes.
    let coverage = coverFixedCharges(
        results: res,
        fixedCharges: input.fixedCharges,
        cutOrder: cutOrder
    )

    // 5. Calcul du montant total réparti.
    let allocated = res.reduce(0.0) {
        $0 + Double($1.amount)
    }

    return MonthAllocation(
        available: available,
        reference: input.reference,
        base: base,
        surplus: surplus,
        fixedCharges: input.fixedCharges,
        fixedMargin: coverage.fixedMargin,
        shortFall: coverage.shortfall,
        unallocated: max(available - allocated, 0),
        buckets: res
    )
}