import Foundation

// Top-level entrypoint for the executable target.
// (Do NOT use @main if the module has any other top-level code.)
do {
    try LLMintyApp().run()
} catch {
    fputs("llminty: \(error.localizedDescription)\n", stderr)
    exit(1)
}
