// Moteur de répartition mensuelle, porté de Kopek web (src/lib/engine/allocation.ts).
// Fonctions pures, sans UIKit ni SwiftUI (ni même Foundation) : testables isolément.
//
// Règle des types :
// - tous les montants sont des entiers en centimes (`Int`, 64 bits sur toutes les plateformes Apple actuelles) ;
// - seuls les pourcentages (`percent`, `urssafRate`, `surplusSavingsPct`) sont des `Double`.
//
// Règle des arrondis (JS -> Swift) :
// - `Math.round` de JS arrondit les demi-valeurs vers +∞ (2,5 -> 3 ; -2,5 -> -2). Aucune règle de
//   `FloatingPointRoundingRule` ne fait exactement ça : `.toNearestOrAwayFromZero` (celle de `rounded()` et de
//   `round()`) donne -3 pour -2,5, et `.toNearestOrEven` donne 2 pour 2,5. On écrit donc `jsRound` à la main.
// - `Math.floor` / `Math.ceil` de JS -> `rounded(.down)` / `rounded(.up)`, puis `Int(...)`.

/// Type d'un revenu. Les valeurs brutes sont celles de l'API web.
public enum IncomeType: String, Sendable, CaseIterable {
    case salary = "SALARY"
    case selfEmployed = "SELF_EMPLOYED"
    case thirdParty = "THIRD_PARTY"
    case other = "OTHER"
}

/// Famille d'une catégorie de la règle de répartition. Les valeurs brutes sont celles de l'API web.
public enum BucketKind: String, Sendable, CaseIterable {
    case fixed = "FIXED"
    case lifestyle = "LIFESTYLE"
    case saving = "SAVING"
    case envelope = "ENVELOPE"
}

/// Fréquence de paiement d'une charge récurrente. Les valeurs brutes sont celles de l'API web.
public enum ChargeFrequency: String, Sendable, CaseIterable {
    case monthly = "MONTHLY"
    case quarterly = "QUARTERLY"
    case yearly = "YEARLY"

    /// Nombre de paiements par an : un `switch` exhaustif, le compilateur refuse un cas oublié.
    var occurrencesPerYear: Int {
        switch self {
        case .monthly: 12
        case .quarterly: 4
        case .yearly: 1
        }
    }
}

/// Erreur levée par le moteur pour une entrée invalide.
public enum EngineError: Error, Equatable, Sendable {
    /// Un pourcentage de catégorie est négatif.
    case negativePercent(bucketID: String, value: Double)
    /// Un montant fixe de catégorie est négatif.
    case negativeFixedAmount(bucketID: String, value: Int)
    /// `surplusSavingsPct` sort de 0...100.
    case surplusSavingsPctOutOfRange(Double)
    /// `urssafRate` est négatif.
    case negativeUrssafRate(Double)
}

/// Ordre dans lequel on rogne pour payer les charges fixes quand le mois est faible.
private let cutOrder: [BucketKind] = [.lifestyle, .envelope, .saving]

/// Équivalent exact de `Math.round` de JS : demi-valeurs vers +∞.
private func jsRound(_ value: Double) -> Int {
    let down = value.rounded(.down)
    return Int(value - down >= 0.5 ? down + 1 : down)
}

/// Arrondi au dixième, comme `Math.round(n * 10) / 10` en JS.
private func roundToTenth(_ value: Double) -> Double {
    Double(jsRound(value * 10)) / 10
}

// MARK: - Charges

/// Équivalent mensuel d'une charge selon sa fréquence (ex. une assurance payée une fois par an, lissée sur 12 mois).
///
/// - Parameters:
///   - amount: montant d'un paiement, en centimes.
///   - frequency: fréquence de paiement.
/// - Returns: le montant mensuel lissé, en centimes, arrondi comme `Math.round` de JS.
public func monthlyEquivalent(of amount: Int, frequency: ChargeFrequency) -> Int {
    jsRound(Double(amount * frequency.occurrencesPerYear) / 12)
}

/// Une charge récurrente (loyer, assurance…), en centimes par paiement.
public struct RecurringCharge: Equatable, Sendable {
    public let id: String
    public let label: String
    public let amount: Int
    public let frequency: ChargeFrequency
    public let active: Bool

    // Un struct public n'a qu'un init memberwise `internal` : sans cet init, l'appli ne pourrait pas en créer.
    public init(id: String, label: String, amount: Int, frequency: ChargeFrequency, active: Bool) {
        self.id = id
        self.label = label
        self.amount = amount
        self.frequency = frequency
        self.active = active
    }
}

/// Une dépense de charge fixe générée pour un mois.
public struct ChargeExpense: Equatable, Sendable {
    public let userID: String
    public let month: String
    public let label: String
    public let amount: Int
    public let kind: BucketKind
    public let category: String
    public let recurringChargeID: String
}

/// Dépenses à créer pour un mois à partir des charges actives : une ligne par charge, à son équivalent mensuel.
///
/// - Parameters:
///   - charges: les charges récurrentes de l'utilisateur.
///   - userId: identifiant de l'utilisateur.
///   - month: mois au format « AAAA-MM ».
public func expensesFromCharges(_ charges: [RecurringCharge], userId: String, month: String) -> [ChargeExpense] {
    charges
        .filter(\.active)
        .map { charge in
            ChargeExpense(
                userID: userId,
                month: month,
                label: charge.label,
                amount: monthlyEquivalent(of: charge.amount, frequency: charge.frequency),
                kind: .fixed,
                category: "Charges fixes",
                recurringChargeID: charge.id
            )
        }
}

// MARK: - Revenus

/// Un revenu du mois, en centimes.
public struct Income: Equatable, Sendable {
    public let type: IncomeType
    public let amount: Int

    public init(type: IncomeType, amount: Int) {
        self.type = type
        self.amount = amount
    }
}

/// Synthèse des revenus d'un mois, en centimes.
public struct IncomeSummary: Equatable, Sendable {
    /// Tous les revenus du mois, argent d'un tiers compris.
    public let gross: Int
    /// Chiffre d'affaires de micro-entreprise.
    public let selfEmployed: Int
    /// Provision de cotisations URSSAF.
    public let urssaf: Int
    /// Ce qui est réellement à répartir : `gross - urssaf`.
    public let net: Int
}

/// Additionne les revenus du mois et provisionne l'URSSAF sur le chiffre d'affaires de micro-entreprise.
///
/// - Parameters:
///   - incomes: les revenus du mois.
///   - urssafRate: taux de cotisation en % (ex. 25.6).
/// - Throws: `EngineError.negativeUrssafRate` si le taux est négatif.
public func summarizeIncomes(_ incomes: [Income], urssafRate: Double) throws(EngineError) -> IncomeSummary {
    guard urssafRate >= 0 else { throw EngineError.negativeUrssafRate(urssafRate) }
    let gross = incomes.reduce(0) { $0 + $1.amount }
    let selfEmployed = incomes.filter { $0.type == .selfEmployed }.reduce(0) { $0 + $1.amount }
    let urssaf = jsRound(Double(selfEmployed) * urssafRate / 100)
    return IncomeSummary(gross: gross, selfEmployed: selfEmployed, urssaf: urssaf, net: gross - urssaf)
}

/// Revenu de référence : moyenne des mois précédents qui ont au moins un revenu, arrondie comme `Math.round` de JS.
///
/// - Parameter pastNets: revenus nets des mois précédents, en centimes.
/// - Returns: la moyenne arrondie, ou 0 si aucun mois n'a de revenu.
public func referenceIncome(pastNets: [Int]) -> Int {
    let months = pastNets.filter { $0 > 0 }
    guard !months.isEmpty else { return 0 }
    // Division en Double : une division entière tronquerait (1,5 -> 1 au lieu de 2).
    return jsRound(Double(months.reduce(0, +)) / Double(months.count))
}

/// Revenu minimum pour que les charges fixes restent sous `fixedPct` % du revenu.
///
/// - Parameters:
///   - fixedCharges: charges fixes mensuelles, en centimes.
///   - fixedPct: part maximale des charges fixes, en %.
/// - Returns: le revenu minimum en centimes, arrondi au centime supérieur ; 0 si `fixedPct` vaut 0 ou moins.
public func minIncomeForFixedCharges(_ fixedCharges: Int, fixedPct: Double) -> Int {
    guard fixedPct > 0 else { return 0 }
    return Int((Double(fixedCharges) * 100 / fixedPct).rounded(.up))
}

// MARK: - Règle de répartition

/// Une catégorie de la règle de répartition.
public struct BucketInput: Equatable, Sendable {
    public let id: String
    public let name: String
    public let kind: BucketKind
    /// Part en % du revenu ; ignorée si `fixedAmount` est renseigné.
    public let percent: Double
    /// Montant fixe mensuel en centimes, ou `nil` pour une catégorie en pourcentage.
    public let fixedAmount: Int?

    public init(id: String, name: String, kind: BucketKind, percent: Double, fixedAmount: Int? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.percent = percent
        self.fixedAmount = fixedAmount
    }
}

/// Ce que répartit une règle, en % d'un mois de revenu (voir `ruleTotal(of:income:)`).
public struct RuleTotal: Equatable, Sendable {
    /// Somme des pourcentages, arrondie au dixième.
    public let percents: Double
    /// Somme des montants fixes, en centimes.
    public let fixed: Int
    /// Montants fixes rapportés au revenu, en %, ou `nil` s'il y en a mais que le revenu est inconnu.
    public let fixedPercent: Double?
    /// `percents + fixedPercent`, ou `nil` quand `fixedPercent` l'est. Doit valoir 100.
    public let total: Double?

    public init(percents: Double, fixed: Int, fixedPercent: Double?, total: Double?) {
        self.percents = percents
        self.fixed = fixed
        self.fixedPercent = fixedPercent
        self.total = total
    }
}

/// Ce que la règle répartit, en % d'un mois de revenu (en pratique le revenu moyen) : les pourcentages plus les
/// montants fixes rapportés à ce revenu (150 € sur 750 € = 20 %). Sans revenu connu, les montants fixes ne se
/// convertissent pas : `total` est `nil` s'il y en a.
///
/// - Parameters:
///   - buckets: les catégories de la règle.
///   - income: revenu de référence, en centimes.
public func ruleTotal(of buckets: [BucketInput], income: Int) -> RuleTotal {
    let percents = roundToTenth(buckets.filter { $0.fixedAmount == nil }.reduce(0.0) { $0 + $1.percent })
    let fixed = buckets.reduce(0) { $0 + ($1.fixedAmount ?? 0) }
    let fixedPercent: Double?
    if fixed == 0 {
        fixedPercent = 0
    } else if income > 0 {
        fixedPercent = roundToTenth(Double(fixed) * 100 / Double(income))
    } else {
        fixedPercent = nil
    }
    let total = fixedPercent.map { roundToTenth(percents + $0) }
    return RuleTotal(percents: percents, fixed: fixed, fixedPercent: fixedPercent, total: total)
}

/// Part réelle d'une catégorie, en %.
public struct BucketShare: Equatable, Sendable {
    public let id: String
    public let share: Double
}

/// Part réelle de chaque catégorie dans un mois de revenu `income`, en % (même calcul que `allocateMonth` hors
/// surplus et charges fixes) : les montants fixes d'abord, puis le reste partagé au prorata des pourcentages. Sans
/// revenu connu, les montants fixes comptent pour 0 et les pourcentages se partagent 100 %.
///
/// - Returns: une part par catégorie, dans l'ordre des catégories (un tableau, car un dictionnaire n'a pas d'ordre).
public func effectiveShares(of buckets: [BucketInput], income: Int) -> [BucketShare] {
    let fixedTotal = buckets.reduce(0) { $0 + ($1.fixedAmount ?? 0) }
    let weights = buckets.filter { $0.fixedAmount == nil }.reduce(0.0) { $0 + $1.percent }
    let fixedShare = income > 0 ? min(Double(fixedTotal) * 100 / Double(income), 100) : 0
    return buckets.map { bucket in
        let share: Double
        if let fixedAmount = bucket.fixedAmount {
            share = fixedTotal > 0 ? fixedShare * Double(fixedAmount) / Double(fixedTotal) : 0
        } else {
            share = weights > 0 ? (100 - fixedShare) * bucket.percent / weights : 0
        }
        return BucketShare(id: bucket.id, share: share)
    }
}

// MARK: - Répartition du mois

/// Résultat d'une catégorie après répartition, en centimes.
public struct BucketResult: Equatable, Sendable {
    public let input: BucketInput
    /// Part issue du revenu « normal ».
    public internal(set) var base: Int
    /// Bonus d'un mois plus fort que la référence.
    public internal(set) var fromSurplus: Int
    /// +/- pour couvrir les charges fixes.
    public internal(set) var adjustment: Int
    /// Montant final conseillé.
    public internal(set) var amount: Int
}

/// Résultat de `allocateMonth`, en centimes.
public struct MonthAllocation: Equatable, Sendable {
    public let available: Int
    public let reference: Int
    public let base: Int
    public let surplus: Int
    public let fixedCharges: Int
    /// Reste dans les catégories FIXED après les charges fixes (courses, essence…).
    public let fixedMargin: Int
    /// Manque à prendre sur le matelas de sécurité.
    public let shortfall: Int
    /// Ce qui reste sans catégorie en pourcentage pour le recevoir (aucune, ou toutes à 0 %).
    public let unallocated: Int
    public let buckets: [BucketResult]
}

/// Répartit `total` proportionnellement aux poids, en centimes entiers, sans perte d'arrondi : chaque part est
/// arrondie vers le bas, puis les centimes restants sont distribués un par un depuis le début.
private func spread(_ total: Int, weights: [Double]) -> [Int] {
    guard total > 0, !weights.isEmpty else { return weights.map { _ in 0 } }
    let sum = weights.reduce(0, +)
    guard sum > 0 else { return weights.map { _ in 0 } }
    var shares = weights.map { Int((Double(total) * $0 / sum).rounded(.down)) }
    var rest = total - shares.reduce(0, +)
    var index = 0
    while rest > 0 {
        shares[index] += 1
        rest -= 1
        index = (index + 1) % shares.count
    }
    return shares
}

/// Répartit le revenu net d'un mois entre les catégories de la règle.
///
/// 1. Mois fort (`net > reference`) : la référence est répartie selon la règle, le surplus à part
///    (`surplusSavingsPct` % vers l'épargne et les enveloppes en pourcentage, le reste au prorata).
/// 2. Les montants fixes sont prélevés d'abord, les pourcentages se partagent le reste.
/// 3. Mois faible : les charges fixes sont incompressibles, on rogne plaisir, puis enveloppes, puis épargne.
///
/// - Parameters:
///   - net: revenu net du mois, en centimes (un négatif compte pour 0).
///   - reference: revenu de référence (voir `referenceIncome(pastNets:)`), en centimes ; 0 si inconnu.
///   - fixedCharges: charges fixes du mois, en centimes.
///   - buckets: les catégories de la règle.
///   - surplusSavingsPct: part du surplus envoyée à l'épargne, en % (0 à 100).
/// - Throws: `EngineError` si un pourcentage ou un montant fixe est négatif, ou si `surplusSavingsPct` sort de 0...100.
public func allocateMonth(
    net: Int,
    reference: Int,
    fixedCharges: Int,
    buckets: [BucketInput],
    surplusSavingsPct: Double
) throws(EngineError) -> MonthAllocation {
    guard (0...100).contains(surplusSavingsPct) else { throw EngineError.surplusSavingsPctOutOfRange(surplusSavingsPct) }
    for bucket in buckets {
        guard bucket.percent >= 0 else { throw EngineError.negativePercent(bucketID: bucket.id, value: bucket.percent) }
        if let fixedAmount = bucket.fixedAmount, fixedAmount < 0 {
            throw EngineError.negativeFixedAmount(bucketID: bucket.id, value: fixedAmount)
        }
    }

    let available = max(net, 0)

    // 1. Mois fort : on répartit la référence selon la règle, le surplus est traité à part.
    let base = reference > 0 && available > reference ? reference : available
    let surplus = available - base

    // État modifiable LOCAL : un tableau de structs (types valeur), modifié sur place, jamais partagé.
    var res = buckets.map { BucketResult(input: $0, base: 0, fromSurplus: 0, adjustment: 0, amount: 0) }

    let fixedIndices = res.indices.filter { res[$0].input.fixedAmount != nil }
    let flexibleIndices = res.indices.filter { res[$0].input.fixedAmount == nil }
    let totalFixedAmount = fixedIndices.reduce(0) { $0 + (res[$1].input.fixedAmount ?? 0) }

    if totalFixedAmount > base {
        // Les montants fixes à eux seuls dépassent l'argent disponible : on les réduit proportionnellement.
        let shares = spread(base, weights: fixedIndices.map { Double(res[$0].input.fixedAmount ?? 0) })
        for (i, index) in fixedIndices.enumerated() { res[index].base = shares[i] }
    } else {
        for index in fixedIndices { res[index].base = res[index].input.fixedAmount ?? 0 }
        let shares = spread(base - totalFixedAmount, weights: flexibleIndices.map { res[$0].input.percent })
        for (i, index) in flexibleIndices.enumerated() { res[index].base = shares[i] }
    }

    if surplus > 0 {
        // Un montant fixe ne grossit pas les mois forts : seules les catégories en pourcentage profitent du surplus.
        let saverIndices = flexibleIndices.filter {
            let bucket = res[$0].input
            return (bucket.kind == .saving || bucket.kind == .envelope) && bucket.percent > 0
        }
        let toSavers = saverIndices.isEmpty ? 0 : jsRound(Double(surplus) * surplusSavingsPct / 100)
        let saverShares = spread(toSavers, weights: saverIndices.map { res[$0].input.percent })
        for (i, index) in saverIndices.enumerated() { res[index].fromSurplus += saverShares[i] }
        let otherShares = spread(surplus - toSavers, weights: flexibleIndices.map { res[$0].input.percent })
        for (i, index) in flexibleIndices.enumerated() { res[index].fromSurplus += otherShares[i] }
    }
    for index in res.indices { res[index].amount = res[index].base + res[index].fromSurplus }

    // 2. Mois faible : les charges fixes sont incompressibles, on rogne plaisir -> enveloppes -> épargne.
    // Sans catégorie FIXED, on ne devine pas où rogner : les charges fixes deviennent un manque direct.
    let fixedKindIndices = res.indices.filter { res[$0].input.kind == .fixed }
    let fixedBudget = fixedKindIndices.reduce(0) { $0 + res[$1].amount }
    var gap = fixedKindIndices.isEmpty ? fixedCharges : fixedCharges - fixedBudget
    var covered = 0

    if gap > 0 && !fixedKindIndices.isEmpty {
        for kind in cutOrder {
            if gap <= 0 { break }
            let group = res.indices.filter { res[$0].input.kind == kind && res[$0].amount > 0 }
            let pool = group.reduce(0) { $0 + res[$1].amount }
            let take = min(pool, gap)
            let shares = spread(take, weights: group.map { Double(res[$0].amount) })
            for (i, index) in group.enumerated() {
                res[index].adjustment -= shares[i]
                res[index].amount -= shares[i]
            }
            gap -= take
            covered += take
        }
        // `b.percent || 1` en JS : un poids de 1 pour une catégorie FIXED à 0 %.
        let fixedWeights = fixedKindIndices.map { res[$0].input.percent != 0 ? res[$0].input.percent : 1 }
        let shares = spread(covered, weights: fixedWeights)
        for (i, index) in fixedKindIndices.enumerated() {
            res[index].adjustment += shares[i]
            res[index].amount += shares[i]
        }
    }

    let fixedAfter = fixedKindIndices.reduce(0) { $0 + res[$1].amount }
    let allocated = res.reduce(0) { $0 + $1.amount }

    return MonthAllocation(
        available: available,
        reference: reference,
        base: base,
        surplus: surplus,
        fixedCharges: fixedCharges,
        fixedMargin: fixedKindIndices.isEmpty ? 0 : max(fixedAfter - fixedCharges, 0),
        shortfall: max(gap, 0),
        unallocated: max(available - allocated, 0),
        buckets: res
    )
}

// MARK: - Dépenses réelles

/// Une dépense réelle du mois, réduite à ce dont la comparaison a besoin.
public struct ExpenseInput: Equatable, Sendable {
    public let kind: BucketKind
    public let amount: Int

    public init(kind: BucketKind, amount: Int) {
        self.kind = kind
        self.amount = amount
    }
}

/// Objectif de la règle contre dépenses réelles pour une famille de catégories, en centimes.
public struct ExpenseComparison: Equatable, Sendable {
    public let kind: BucketKind
    public let objective: Int
    public let actual: Int
    /// `objective - actual` : positif s'il reste de la marge.
    public let delta: Int
}

/// Compare les dépenses réelles du mois aux montants de la règle de répartition, par famille de catégories.
///
/// - Returns: une ligne par `BucketKind` qui a un objectif ou des dépenses, dans l'ordre de l'enum.
public func summarizeExpenses(_ expenses: [ExpenseInput], buckets: [BucketResult]) -> [ExpenseComparison] {
    BucketKind.allCases
        .map { kind in
            let objective = buckets.filter { $0.input.kind == kind }.reduce(0) { $0 + $1.amount }
            let actual = expenses.filter { $0.kind == kind }.reduce(0) { $0 + $1.amount }
            return ExpenseComparison(kind: kind, objective: objective, actual: actual, delta: objective - actual)
        }
        .filter { $0.objective > 0 || $0.actual > 0 }
}
