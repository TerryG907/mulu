/// Which recognition sheet a document window is showing.
enum SessionSheet: String, Identifiable {
    case recognize, paste
    var id: Self { self }
}
