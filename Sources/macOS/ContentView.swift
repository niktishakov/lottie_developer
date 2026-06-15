#if os(macOS)
import SwiftUI

/// Роутер: Home (список проектов) ↔ Editor (проект).
struct ContentView: View {
    @State private var store = ProjectStore()
    @State private var openProjectID: UUID?

    var body: some View {
        Group {
            if let id = openProjectID, store.project(id) != nil {
                EditorView(store: store, projectID: id, onClose: { openProjectID = nil })
            } else {
                HomeView(store: store, onOpen: { openProjectID = $0 })
            }
        }
        .frame(minWidth: 760, minHeight: 660)
    }
}
#endif
