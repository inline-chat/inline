import InlineIOSFoundation
import Testing

@Suite("FormDiff")
struct FormDiffTests {
  private func section(_ id: String, header: String? = nil, footer: String? = nil, _ rows: [FormRow]) -> FormSection {
    FormSection(id, header: header, footer: footer, rows: rows)
  }

  @Test func firstRenderHasNoReconfigures() {
    let new = [section("a", [.value("x", "X", value: "1"), .value("y", "Y", value: "2")])]
    let (plan, sanitized) = FormDiff.plan(old: [], new: new)
    #expect(plan.sections == ["a"])
    #expect(plan.items["a"] == [FormItemID(section: "a", row: "x"), FormItemID(section: "a", row: "y")])
    #expect(plan.reconfigure.isEmpty)
    #expect(plan.reloadSections.isEmpty)
    #expect(sanitized.count == 1)
  }

  @Test func changedContentIsReconfiguredUnchangedIsNot() {
    let old = [section("a", [.value("x", "X", value: "1"), .value("y", "Y", value: "2")])]
    let new = [section("a", [.value("x", "X", value: "1"), .value("y", "Y", value: "3")])]
    let (plan, _) = FormDiff.plan(old: old, new: new)
    #expect(plan.reconfigure == [FormItemID(section: "a", row: "y")])
  }

  @Test func toggleStateChangeReconfigures() {
    let old = [section("a", [.toggle("t", "T", isOn: false) { _ in }])]
    let new = [section("a", [.toggle("t", "T", isOn: true) { _ in }])]
    #expect(FormDiff.plan(old: old, new: new).plan.reconfigure == [FormItemID(section: "a", row: "t")])
  }

  @Test func insertsAndRemovalsAreNotReconfigures() {
    let old = [section("a", [.value("x", "X", value: "1")])]
    let new = [section("a", [.value("y", "Y", value: "1")]), section("b", [.value("x", "X", value: "1")])]
    let (plan, _) = FormDiff.plan(old: old, new: new)
    #expect(plan.sections == ["a", "b"])
    // Row "x" moved sections, so its id changed: it is an insert, not a reconfigure.
    #expect(plan.reconfigure.isEmpty)
  }

  @Test func duplicateIdsAreDroppedFirstWins() {
    let new = [
      section("a", [.value("x", "First", value: nil), .value("x", "Second", value: nil)]),
      section("a", [.value("z", "Z", value: nil)]),
    ]
    let (plan, sanitized) = FormDiff.plan(old: [], new: new)
    #expect(plan.sections == ["a"])
    #expect(sanitized[0].rows.map(\.title) == ["First"])
  }

  @Test func headerOrFooterChangeReloadsSection() {
    let old = [section("a", header: "One", [.value("x", "X", value: nil)])]
    let new = [section("a", header: "Two", [.value("x", "X", value: nil)])]
    let (plan, _) = FormDiff.plan(old: old, new: new)
    #expect(plan.reloadSections == ["a"])
    #expect(plan.reconfigure.isEmpty)
  }

  @Test func contentKeyDrivesCustomRowReconfigure() {
    var a = FormRow("c", title: "", contentKey: 1)
    var b = FormRow("c", title: "", contentKey: 2)
    a.onSelect = {}
    b.onSelect = {}
    #expect(a.contentHash != b.contentHash)
    let (plan, _) = FormDiff.plan(old: [section("s", [a])], new: [section("s", [b])])
    #expect(plan.reconfigure == [FormItemID(section: "s", row: "c")])
  }

  @Test func selectabilityRules() {
    #expect(FormRow.navigation("n", "N") {}.isSelectable)
    #expect(!FormRow.toggle("t", "T", isOn: true) { _ in }.isSelectable)
    #expect(!FormRow.note("n", "text").isSelectable)
    #expect(!FormRow.button("b", "B", isEnabled: false) {}.isSelectable)
    #expect(!FormRow.button("b", "B", isLoading: true) {}.isSelectable)
    #expect(!FormRow.value("v", "V", value: "1").isSelectable)
  }

  @Test func builderComposesConditionalsAndLoops() {
    let flag = true
    let items = ["a", "b"]
    let built = FormSection("s") {
      FormRow.value("head", "Head", value: nil)
      if flag {
        FormRow.value("flag", "Flag", value: nil)
      }
      for item in items {
        FormRow.value(item, item, value: nil)
      }
    }
    #expect(built.rows.map(\.id) == ["head", "flag", "a", "b"])
  }
}
