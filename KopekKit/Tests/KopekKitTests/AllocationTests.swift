import Testing
@testable import KopekKit

// Port des cas de Kopek web (scripts/test-engine.ts) qui touchent le moteur de répartition :
// mêmes entrées, mêmes chiffres attendus. Montants en centimes.

private let rule = [
    BucketInput(id: "f", name: "Charges fixes", kind: .fixed, percent: 50),
    BucketInput(id: "l", name: "Plaisir", kind: .lifestyle, percent: 30),
    BucketInput(id: "s", name: "Épargne", kind: .saving, percent: 20),
]

private let leoRule = [
    BucketInput(id: "ep", name: "Épargne", kind: .saving, percent: 0, fixedAmount: 15000),
    BucketInput(id: "f", name: "Charges", kind: .fixed, percent: 50),
    BucketInput(id: "l", name: "Plaisir", kind: .lifestyle, percent: 30),
]

private let thirdRule = [
    BucketInput(id: "x", name: "X", kind: .lifestyle, percent: 33.3),
    BucketInput(id: "y", name: "Y", kind: .saving, percent: 33.3),
    BucketInput(id: "z", name: "Z", kind: .fixed, percent: 33.3),
]

private extension MonthAllocation {
    /// Montant d'une catégorie. Pas de `!` : une catégorie absente vaut 0 et fait échouer le test qui l'attend.
    func by(_ id: String) -> Int {
        buckets.first { $0.input.id == id }?.amount ?? 0
    }
}

private func allocate(
    net: Int,
    reference: Int,
    fixedCharges: Int,
    buckets: [BucketInput],
    surplusSavingsPct: Double = 70
) throws -> MonthAllocation {
    try allocateMonth(
        net: net,
        reference: reference,
        fixedCharges: fixedCharges,
        buckets: buckets,
        surplusSavingsPct: surplusSavingsPct
    )
}

@Suite("allocateMonth")
struct AllocateMonthTests {
    @Test("Mois normal : charges au-dessus de 50 %, on rogne le plaisir")
    func normalMonth() throws {
        let a = try allocate(net: 96100, reference: 0, fixedCharges: 65000, buckets: rule)
        #expect(a.by("f") == 65000)
        #expect(a.by("s") == 19220)
        #expect(a.by("l") == 96100 - 65000 - 19220)
        #expect(a.shortfall == 0)
    }

    @Test("Mois faible : plaisir et épargne à zéro, manque de 250 €")
    func weakMonth() throws {
        let a = try allocate(net: 40000, reference: 96100, fixedCharges: 65000, buckets: rule)
        #expect(a.by("l") == 0)
        #expect(a.by("s") == 0)
        #expect(a.shortfall == 25000)
    }

    @Test("Mois fort : 70 % du surplus en épargne")
    func strongMonth() throws {
        let a = try allocate(net: 300_000, reference: 150_000, fixedCharges: 65000, buckets: rule)
        #expect(a.by("f") == 97500)
        #expect(a.by("l") == 58500)
        #expect(a.by("s") == 144_000)
        #expect(a.unallocated == 0)
    }

    @Test("Sans catégorie FIXED : les charges fixes remontent en manque")
    func noFixedBucket() throws {
        let noFixed = [
            BucketInput(id: "l", name: "Plaisir", kind: .lifestyle, percent: 60),
            BucketInput(id: "s", name: "Épargne", kind: .saving, percent: 40),
        ]
        let a = try allocate(net: 100_000, reference: 0, fixedCharges: 65000, buckets: noFixed)
        #expect(a.by("l") == 60000)
        #expect(a.by("s") == 40000)
        #expect(a.shortfall == 65000)
        #expect(a.unallocated == 0)
    }

    @Test("Montant fixe : prélevé d'abord, les pourcentages se partagent le reste")
    func fixedAmountFirst() throws {
        let fixedRule = [
            BucketInput(id: "f", name: "Charges fixes", kind: .fixed, percent: 50),
            BucketInput(id: "dca", name: "DCA", kind: .saving, percent: 0, fixedAmount: 20000),
            BucketInput(id: "l", name: "Plaisir", kind: .lifestyle, percent: 50),
        ]
        let a = try allocate(net: 100_000, reference: 0, fixedCharges: 40000, buckets: fixedRule)
        #expect(a.by("dca") == 20000)
        #expect(a.by("f") == 40000)
        #expect(a.by("l") == 40000)
        // Un mois fort ne fait pas grossir le montant fixe.
        let strong = try allocate(net: 300_000, reference: 100_000, fixedCharges: 40000, buckets: fixedRule)
        #expect(strong.by("dca") == 20000)
    }

    @Test("Montant fixe : rogné comme les autres quand le mois est faible")
    func fixedAmountCut() throws {
        let weakFixedRule = [
            BucketInput(id: "f", name: "Charges fixes", kind: .fixed, percent: 100),
            BucketInput(id: "dca", name: "DCA", kind: .saving, percent: 0, fixedAmount: 20000),
        ]
        let a = try allocate(net: 50000, reference: 0, fixedCharges: 60000, buckets: weakFixedRule)
        #expect(a.by("dca") == 0)
        #expect(a.shortfall == 10000)
    }

    @Test("Montants fixes trop gros : partagés au prorata de ce qui existe")
    func overcommittedFixedAmounts() throws {
        let overcommitted = [
            BucketInput(id: "dca", name: "DCA", kind: .saving, percent: 0, fixedAmount: 80000),
            BucketInput(id: "vac", name: "Vacances", kind: .envelope, percent: 0, fixedAmount: 80000),
        ]
        let a = try allocate(net: 100_000, reference: 0, fixedCharges: 0, buckets: overcommitted)
        #expect(a.by("dca") + a.by("vac") == 100_000)
        #expect(a.by("dca") == a.by("vac"))
    }

    @Test("Mois fort : une épargne à 0 % ne reçoit rien du surplus")
    func zeroPercentSaver() throws {
        let zeroSaver = [
            BucketInput(id: "s", name: "Épargne", kind: .saving, percent: 0),
            BucketInput(id: "l", name: "Plaisir", kind: .lifestyle, percent: 100),
        ]
        let a = try allocate(net: 200_000, reference: 100_000, fixedCharges: 0, buckets: zeroSaver)
        #expect(a.by("s") == 0)
        #expect(a.by("l") == 200_000)
    }

    @Test("Règle qui ne fait pas 100 % : tout est réparti sans centime perdu")
    func ruleBelowHundred() throws {
        let decimalRule = [BucketInput(id: "x", name: "X", kind: .lifestyle, percent: 0.7)]
        let a = try allocate(net: 11000, reference: 0, fixedCharges: 0, buckets: decimalRule, surplusSavingsPct: 0)
        #expect(a.by("x") == 11000)
    }

    @Test("spread ne perd aucun centime : 3001 centimes en trois tiers")
    func spreadKeepsEveryCent() throws {
        let a = try allocate(net: 3001, reference: 0, fixedCharges: 0, buckets: thirdRule, surplusSavingsPct: 0)
        #expect(a.by("x") + a.by("y") + a.by("z") == 3001)
        #expect(a.unallocated == 0)
    }

    @Test("Règle de Léo : 150 € fixes plus 80 %")
    func leoRuleAverageMonth() throws {
        let a = try allocate(net: 75000, reference: 0, fixedCharges: 0, buckets: leoRule)
        #expect([a.by("ep"), a.by("f"), a.by("l")] == [15000, 37500, 22500])
        #expect(a.unallocated == 0)
        let b = try allocate(net: 100_000, reference: 0, fixedCharges: 0, buckets: leoRule)
        #expect(b.by("f") + b.by("l") == 85000)
        #expect(b.unallocated == 0)
    }

    @Test("Règle de Léo, mois faible : le fixe puis le plaisir sont rognés")
    func leoRuleWeakMonth() throws {
        let a = try allocate(net: 60000, reference: 0, fixedCharges: 50000, buckets: leoRule)
        #expect(a.by("f") == 50000)
        #expect(a.by("f") + a.by("l") + a.by("ep") == 60000)
        #expect(a.shortfall == 0)
        let b = try allocate(net: 40000, reference: 0, fixedCharges: 50000, buckets: leoRule)
        #expect([b.by("f"), b.by("l"), b.by("ep")] == [40000, 0, 0])
        #expect(b.shortfall == 10000)
    }

    @Test("Mois fort avec épargne et règle différente de 100 %")
    func strongMonthWithSavings() throws {
        let strongRule = [
            BucketInput(id: "f", name: "Charges", kind: .fixed, percent: 40),
            BucketInput(id: "s", name: "Épargne", kind: .saving, percent: 20),
            BucketInput(id: "dca", name: "DCA", kind: .saving, percent: 0, fixedAmount: 10000),
        ]
        let a = try allocate(net: 150_000, reference: 100_000, fixedCharges: 0, buckets: strongRule)
        #expect(a.by("dca") == 10000)
        #expect(a.by("f") + a.by("s") + a.by("dca") == 150_000)
        #expect(a.by("s") == 30000 + 35000 + 5000)
        #expect(a.unallocated == 0)
    }
}

@Suite("Entrées invalides")
struct InvalidInputTests {
    @Test("surplusSavingsPct hors de 0...100", arguments: [120.0, -1.0])
    func surplusOutOfRange(pct: Double) {
        #expect(throws: EngineError.surplusSavingsPctOutOfRange(pct)) {
            try allocate(net: 100_000, reference: 0, fixedCharges: 0, buckets: rule, surplusSavingsPct: pct)
        }
    }

    @Test("Pourcentage négatif")
    func negativePercent() {
        let negative = [BucketInput(id: "l", name: "Plaisir", kind: .lifestyle, percent: -10)]
        #expect(throws: EngineError.negativePercent(bucketID: "l", value: -10)) {
            try allocate(net: 100_000, reference: 0, fixedCharges: 0, buckets: negative)
        }
    }

    @Test("Taux URSSAF négatif")
    func negativeUrssafRate() {
        #expect(throws: EngineError.negativeUrssafRate(-1)) {
            try summarizeIncomes([], urssafRate: -1)
        }
    }
}

@Suite("Revenus, charges et dépenses")
struct IncomeAndExpenseTests {
    @Test("URSSAF sur le CA, tous les revenus comptés")
    func incomes() throws {
        let s = try summarizeIncomes(
            [
                Income(type: .salary, amount: 96100),
                Income(type: .selfEmployed, amount: 100_000),
                Income(type: .thirdParty, amount: 5000),
            ],
            urssafRate: 25.6
        )
        #expect(s.urssaf == 25600)
        #expect(s.gross == 96100 + 100_000 + 5000)
        #expect(s.net == 96100 + 100_000 + 5000 - 25600)
    }

    @Test("Revenu de référence : moyenne des mois avec revenu")
    func reference() {
        #expect(referenceIncome(pastNets: [0, 100_000, 200_000]) == 150_000)
        #expect(referenceIncome(pastNets: [0, 0]) == 0)
        // Arrondi comme Math.round : 1,5 -> 2 (une division entière donnerait 1).
        #expect(referenceIncome(pastNets: [1, 2]) == 2)
    }

    @Test("Revenu minimum pour les charges fixes")
    func minIncome() {
        #expect(minIncomeForFixedCharges(65000, fixedPct: 50) == 130_000)
        #expect(minIncomeForFixedCharges(65000, fixedPct: 0) == 0)
    }

    @Test("Équivalent mensuel selon la fréquence")
    func monthly() {
        #expect(monthlyEquivalent(of: 6000, frequency: .monthly) == 6000)
        #expect(monthlyEquivalent(of: 6000, frequency: .quarterly) == 2000)
        #expect(monthlyEquivalent(of: 120_000, frequency: .yearly) == 10000)
    }

    @Test("Dépenses réelles contre objectif de la règle")
    func expenses() throws {
        let a = try allocate(net: 96100, reference: 0, fixedCharges: 65000, buckets: rule)
        let cmp = summarizeExpenses(
            [ExpenseInput(kind: .lifestyle, amount: 8000), ExpenseInput(kind: .fixed, amount: 65000)],
            buckets: a.buckets
        )
        let lifestyle = try #require(cmp.first { $0.kind == .lifestyle })
        #expect(lifestyle.objective == a.by("l"))
        #expect(lifestyle.actual == 8000)
        #expect(lifestyle.delta == a.by("l") - 8000)
    }
}

@Suite("ruleTotal et effectiveShares")
struct RuleTests {
    @Test("Total de la règle")
    func total() {
        #expect(ruleTotal(of: leoRule, income: 75000) == RuleTotal(percents: 80, fixed: 15000, fixedPercent: 20, total: 100))
        #expect(ruleTotal(of: leoRule, income: 0) == RuleTotal(percents: 80, fixed: 15000, fixedPercent: nil, total: nil))
        #expect(ruleTotal(of: thirdRule, income: 0).total == 99.9)
        let twoFixed = [
            BucketInput(id: "a", name: "A", kind: .fixed, percent: 33.33),
            BucketInput(id: "b", name: "B", kind: .fixed, percent: 66.67),
        ]
        #expect(ruleTotal(of: twoFixed, income: 0).total == 100)
    }

    @Test("Parts réelles : mêmes chiffres que le moteur un mois moyen")
    func shares() {
        #expect(effectiveShares(of: leoRule, income: 100_000).map(\.share) == [15, 53.125, 31.875])
        // Pas de revenu : les pourcentages se partagent tout.
        #expect(effectiveShares(of: leoRule, income: 0).map(\.share) == [0, 62.5, 37.5])
    }

    @Test("Arrondi identique à Math.round de JS, négatifs compris")
    func jsRounding() {
        // Passe par monthlyEquivalent : 30 / 12 = 2,5 -> 3 ; -30 / 12 = -2,5 -> -2 (comme Math.round).
        #expect(monthlyEquivalent(of: 30, frequency: .monthly) == 30)
        #expect(monthlyEquivalent(of: 10, frequency: .quarterly) == 3)   // 40 / 12 = 3,33 -> 3
        #expect(monthlyEquivalent(of: 30, frequency: .yearly) == 3)      // 30 / 12 = 2,5 -> 3
        #expect(monthlyEquivalent(of: -30, frequency: .yearly) == -2)    // -2,5 -> -2 (rounded() donnerait -3)
    }
}
