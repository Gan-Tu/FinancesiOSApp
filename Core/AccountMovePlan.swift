import Foundation

enum AccountMovePlacement: Equatable, Sendable {
    case before
    case inside
    case after


}

/// Resolves both row-edge ordering and middle-row grouping without mutating
/// data. The sidebar and store share the same acceptance rules.
struct AccountMovePlan {
    let ledgerID: UUID
    let parentID: UUID?
    let orderedSiblingIDs: [UUID]

    static func make(
        accountID: UUID,
        targetID: UUID,
        placement: AccountMovePlacement,
        accounts: [Account]
    ) -> AccountMovePlan? {
        let byID = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard accountID != targetID,
              let source = byID[accountID], let target = byID[targetID],
              source.ledgerID == target.ledgerID, source.kind == target.kind else { return nil }

        let parentID: UUID?
        if placement == .inside {
            // Top-level account-type groups stay top-level. Their order can
            // change among roots of the same kind, but a drop cannot hide one.
            guard source.parentID != nil else { return nil }
            parentID = target.id
        } else {
            guard (source.parentID == nil) == (target.parentID == nil) else { return nil }
            parentID = target.parentID
        }

        var ancestorID = parentID
        var visited = Set<UUID>()
        while let id = ancestorID {
            guard id != accountID, visited.insert(id).inserted,
                  let ancestor = byID[id],
                  ancestor.ledgerID == source.ledgerID,
                  ancestor.kind == source.kind else { return nil }
            ancestorID = ancestor.parentID
        }

        var siblings = accounts.enumerated()
            .filter { _, account in
                account.id != accountID && account.ledgerID == source.ledgerID &&
                account.kind == source.kind && account.parentID == parentID
            }
            .sorted { lhs, rhs in
                if lhs.element.listIndex != rhs.element.listIndex {
                    return lhs.element.listIndex < rhs.element.listIndex
                }
                return lhs.offset < rhs.offset
            }
            .map { $0.element.id }
        if placement == .inside {
            siblings.append(accountID)
        } else {
            guard let targetIndex = siblings.firstIndex(of: targetID) else { return nil }
            siblings.insert(accountID, at: targetIndex + (placement == .after ? 1 : 0))
        }
        return AccountMovePlan(ledgerID: source.ledgerID, parentID: parentID, orderedSiblingIDs: siblings)
    }
}
