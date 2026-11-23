# Response cache and resumable downloads, against a local HTTP server.

# One file served with ranges, Last-Modified and If-Range like a real host, plus a JSON endpoint.
# Change state[:body] / state[:modified] to change the file; state[:ranges] records Range headers.
const STATE = Dict{Symbol,Any}()
reset_state!() = merge!(empty!(STATE), Dict(:body => repeat(UInt8.(0:255), 40),
                                            :modified => "Thu, 11 Sep 2025 12:19:52 GMT",
                                            :ranges => Any[], :json_calls => 0))

function handler(req)
    if startswith(req.target, "/api")
        STATE[:json_calls] += 1
        return HTTP.Response(200, ["Content-Type" => "application/json"], "{\"n\":$(STATE[:json_calls])}")
    end
    body, rng = STATE[:body], HTTP.header(req, "Range", "")
    push!(STATE[:ranges], isempty(rng) ? nothing : rng)
    ifr = HTTP.header(req, "If-Range", "")
    if !isempty(rng) && (isempty(ifr) || ifr == STATE[:modified])
        start = parse(Int, rstrip(split(rng, "=")[2], '-'))
        start >= length(body) && return HTTP.Response(416, ["Content-Range" => "bytes */$(length(body))"], UInt8[])
        return HTTP.Response(206, ["Content-Range" => "bytes $start-$(length(body) - 1)/$(length(body))",
                                   "Last-Modified" => STATE[:modified]], body[start+1:end])
    end
    return HTTP.Response(200, ["Last-Modified" => STATE[:modified]], body)
end

# Leave the first `n` bytes as a partial download, as an interrupted call would.
function interrupted(folder, url, n; name="data.bin")
    write(joinpath(folder, "$name.part"), STATE[:body][1:n])
    write(joinpath(folder, "$name.part.json"), JSON3.write(Dict("url" => url, "validator" => STATE[:modified])))
end


port, sock = HTTP.Sockets.listenany(HTTP.Sockets.IPv4("127.0.0.1"), 18080)   # a free port
server = HTTP.serve!(handler, "127.0.0.1", port; server=sock, verbose=false)
base = "http://127.0.0.1:$port"
url = "$base/data.bin"

try
    @testset "response cache" begin
        reset_state!()
        saved = copy(DataEuropa._CACHE)
        mktempdir() do tmp
            withenv("DATAEUROPA_CACHE" => nothing, "DATAEUROPA_CACHE_TTL" => nothing,
                    "DATAEUROPA_CACHE_DIR" => joinpath(tmp, "cache")) do
                merge!(DataEuropa._CACHE, Dict(:on => nothing, :dir => nothing, :ttl => nothing))
                get_n(q="a") = JSON3.read(DataEuropa._get_body("$base/api"; query=Dict("q" => q), cacheable=true)).n
                @test get_n() == 1 && get_n() == 2                         # off by default
                @test cache_on() == joinpath(tmp, "cache")
                @test get_n() == 3 && get_n() == 3                         # second from the cache
                @test get_n("b") == 4                                      # other parameters
                @test JSON3.read(DataEuropa._get_body("$base/api"; cacheable=false)).n == 5   # not cacheable
                @test clear_cache() == 2
                @test get_n() == 6
                cache_off()
                @test get_n() == 7
                cache_on(; ttl=0)                                          # everything already too old
                @test get_n() == 8 && get_n() == 9
                merge!(DataEuropa._CACHE, Dict(:on => nothing, :dir => nothing, :ttl => nothing))
                withenv("DATAEUROPA_CACHE" => "1") do
                    @test get_n("c") == 10 && get_n("c") == 10
                end
            end
        end
        merge!(DataEuropa._CACHE, saved)
    end

    @testset "resumable downloads" begin
        mktempdir() do tmp
            reset_state!()
            path = download_distribution(url, tmp)
            @test read(path) == STATE[:body] && readdir(tmp) == ["data.bin"]   # no leftovers
        end
        mktempdir() do tmp                                                  # resumes
            reset_state!(); interrupted(tmp, url, 1000)
            @test read(download_distribution(url, tmp)) == STATE[:body]
            @test STATE[:ranges] == ["bytes=1000-"] && readdir(tmp) == ["data.bin"]
        end
        mktempdir() do tmp                                                  # file changed meanwhile
            reset_state!(); interrupted(tmp, url, 1000)
            STATE[:modified] = "Fri, 12 Sep 2025 08:00:00 GMT"; STATE[:body] = Vector{UInt8}(repeat("new content", 100))
            @test read(download_distribution(url, tmp)) == STATE[:body]
        end
        mktempdir() do tmp                                                  # partial file too long: 416
            reset_state!(); interrupted(tmp, url, 1000)
            STATE[:body] = STATE[:body][1:500]
            @test read(download_distribution(url, tmp)) == STATE[:body]
            @test STATE[:ranges] == ["bytes=1000-", nothing]
        end
        mktempdir() do tmp                                                  # resume=false
            reset_state!(); interrupted(tmp, url, 1000)
            @test read(download_distribution(url, tmp; resume=false)) == STATE[:body]
            @test STATE[:ranges] == [nothing]
        end
        mktempdir() do tmp                                                  # .part of another URL
            reset_state!(); interrupted(tmp, "http://elsewhere.example/data.bin", 1000)
            @test read(download_distribution(url, tmp)) == STATE[:body]
            @test STATE[:ranges] == [nothing]
        end
    end
finally
    close(server)
end
