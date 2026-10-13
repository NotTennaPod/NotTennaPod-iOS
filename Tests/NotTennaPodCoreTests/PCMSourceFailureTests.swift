import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.serialized) struct PCMSourceFailureTests {
    @Test func concurrentSubscribeFailAndRetireHaveOneConsistentOutcome() async {
        for _ in 0..<200 {
            let source = PCMSourceFailure()
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<8 {
                    group.addTask {
                        var iterator = source.events().makeAsyncIterator()
                        let event = await iterator.next()
                        #expect((event as? URLError)?.code == (source.error as? URLError)?.code)
                        #expect(await iterator.next() == nil)
                    }
                }
                group.addTask { source.fail(URLError(.networkConnectionLost)) }
                group.addTask { source.fail(URLError(.timedOut)) }
                group.addTask { source.finish() }
            }
            #expect(source.subscriberCount == 0)
        }
    }
}
