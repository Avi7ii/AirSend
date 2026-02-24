use localsend::Client;

fn main() {
    // 这将导致编译错误，我们可以从中看到 Client 的构造函数
    let _ = Client::new();
}
