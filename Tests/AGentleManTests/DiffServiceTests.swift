@testable import AGentleMan
import Testing

@Suite("DiffService")
struct DiffServiceTests {
    let service = DiffService()

    @Test("parses file changes from unified diff")
    func parsesUnifiedDiff() async {
        let diff = """
        diff --git a/src/app/layout.tsx b/src/app/layout.tsx
        index abc1234..def5678 100644
        --- a/src/app/layout.tsx
        +++ b/src/app/layout.tsx
        @@ -1,3 +1,4 @@
         import React from 'react'
        +import { Subscription } from './subscription'
         export default function Layout() {
        -  return <div />
        +  return <div><Subscription /></div>
        diff --git a/src/components/subscription.tsx b/src/components/subscription.tsx
        new file mode 100644
        --- /dev/null
        +++ b/src/components/subscription.tsx
        @@ -0,0 +1,5 @@
        +export function Subscription() {
        +  return <div>Sub</div>
        +}
        """

        let changes = await service.parseChanges(from: diff)

        #expect(changes.count == 2)
        #expect(changes[0].path == "src/app/layout.tsx")
        #expect(changes[0].insertions == 2)
        #expect(changes[0].deletions == 1)
        #expect(changes[0].status == .modified)
        #expect(changes[1].path == "src/components/subscription.tsx")
        #expect(changes[1].insertions == 3)
        #expect(changes[1].status == .added)
    }

    @Test("returns empty for no diff")
    func emptyDiff() async {
        let changes = await service.parseChanges(from: "")
        #expect(changes.isEmpty)
    }
}
