# Run in a child process so a pipe deadlock cannot hang the test runner itself.
using Fromage: ShareIO
using OhMyThreads: tmap

for round in 1:4
    bytes = tmap(1:8) do _
        ShareIO.capture(
            `sh -c 'head -c 262144 /dev/zero; head -c 262144 /dev/zero >&2'`,
            "concurrent pipe capture"; tries = 1
        )
    end
    @assert all(b -> length(b) == 262144 && all(iszero, b), bytes)
    println("concurrent pipe capture round $round completed")
    flush(stdout)
end
