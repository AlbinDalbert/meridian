defmodule Meridian.Extensions.HTTPTest do
  use ExUnit.Case, async: true

  alias Meridian.Extensions.HTTP
  alias Meridian.HTTPTestServer

  # The test server is on localhost, which scripts can't reach.
  defp request(request, opts \\ []), do: HTTP.request(request, [allow_local: true] ++ opts)

  describe "requests" do
    setup do
      %{url: HTTPTestServer.start()}
    end

    test "return the status, headers and body", %{url: url} do
      assert {:ok, response} = request(%{"url" => url <> "/hello"})
      assert %{"status" => 200, "body" => "hi"} = response
      assert response["headers"]["x-test"] == "yes"
      refute Map.has_key?(response, "truncated")
    end

    test "send the method, headers and body", %{url: url} do
      assert {:ok, %{"body" => echo}} =
               request(%{
                 "method" => "post",
                 "url" => url <> "/echo",
                 "headers" => %{"X-Token" => "abc", "X-Number" => 2, "Host" => "evil.test"},
                 "body" => "data"
               })

      echo = Jason.decode!(echo)
      assert %{"method" => "POST", "body" => "data"} = echo
      assert echo["headers"]["x-token"] == "abc"
      assert echo["headers"]["x-number"] == "2"
      assert echo["headers"]["host"] =~ "127.0.0.1"
    end

    test "error statuses are responses", %{url: url} do
      assert {:ok, %{"status" => 404, "body" => "status 404"}} =
               request(%{"url" => url <> "/status/404"})
    end

    test "follow redirects", %{url: url} do
      to = URI.encode_www_form("/echo")

      assert {:ok, %{"status" => 200, "body" => echo}} =
               request(%{"method" => "POST", "url" => "#{url}/redirect/303?#{to}", "body" => "x"})

      assert %{"method" => "GET", "body" => ""} = Jason.decode!(echo)

      assert {:ok, %{"body" => echo}} =
               request(%{"method" => "POST", "url" => "#{url}/redirect/307?#{to}", "body" => "x"})

      assert %{"method" => "POST", "body" => "x"} = Jason.decode!(echo)
    end

    test "don't send credentials to another host", %{url: url} do
      other = String.replace(url, "127.0.0.1", "localhost")
      headers = %{"authorization" => "Bearer secret", "x-other" => "kept"}

      to = URI.encode_www_form(other <> "/echo")

      assert {:ok, %{"body" => echo}} =
               request(%{"url" => "#{url}/redirect/302?#{to}", "headers" => headers})

      assert %{"x-other" => "kept"} = echo_headers = Jason.decode!(echo)["headers"]
      refute Map.has_key?(echo_headers, "authorization")

      to = URI.encode_www_form("/echo")

      assert {:ok, %{"body" => echo}} =
               request(%{"url" => "#{url}/redirect/302?#{to}", "headers" => headers})

      assert Jason.decode!(echo)["headers"]["authorization"] == "Bearer secret"
    end

    test "give up on redirect loops", %{url: url} do
      to = URI.encode_www_form("/redirect/302?" <> URI.encode_www_form("/hello"))
      assert {:ok, %{"body" => "hi"}} = request(%{"url" => "#{url}/redirect/302?#{to}"})
      assert {:error, "too many redirects"} = request(%{"url" => url <> "/loop"})
    end

    test "cut big bodies", %{url: url} do
      assert {:ok, %{"body" => body, "truncated" => true}} =
               request(%{"url" => url <> "/big"}, max_body_bytes: 100)

      assert body == String.duplicate("x", 100)
      assert {:ok, %{"body" => body}} = request(%{"url" => url <> "/big"}, max_body_bytes: 1000)
      assert byte_size(body) == 1000
    end

    test "time out", %{url: url} do
      assert {:error, "timed out"} = request(%{"url" => url <> "/slow"}, timeout: 100)
    end
  end

  describe "addresses" do
    test "private and reserved ones are blocked" do
      for url <- [
            "http://127.0.0.1/",
            "http://localhost:4000/",
            "http://10.1.2.3/",
            "http://169.254.169.254/latest/meta-data",
            "http://[::1]/",
            "http://[::ffff:192.168.0.1]/",
            "http://[fd00::1]/"
          ] do
        assert {:error, message} = HTTP.request(%{"url" => url})
        assert message =~ "private or reserved address", url
      end
    end

    test "public?" do
      for address <- [{8, 8, 8, 8}, {172, 32, 0, 1}, {2606, 0x4700, 0, 0, 0, 0, 0, 0x1111}],
          do: assert(HTTP.public?(address), inspect(address))

      for address <- [
            {0, 0, 0, 0},
            {100, 64, 0, 1},
            {172, 16, 0, 1},
            {192, 0, 0, 1},
            {198, 18, 0, 1},
            {224, 0, 0, 1},
            {255, 255, 255, 255},
            {0, 0, 0, 0, 0, 0, 0, 0},
            {0x64, 0xFF9B, 0, 0, 0, 0, 0x0A00, 0x0001},
            {0xFE80, 0, 0, 0, 0, 0, 0, 1},
            {0xFF02, 0, 0, 0, 0, 0, 0, 1}
          ],
          do: refute(HTTP.public?(address), inspect(address))
    end
  end

  test "bad requests" do
    assert {:error, "url must be a string"} = HTTP.request(%{})

    assert {:error, "only http and https URLs are allowed"} =
             HTTP.request(%{"url" => "ftp://a.b"})

    assert {:error, "only http and https URLs are allowed"} =
             HTTP.request(%{"url" => "/relative"})

    assert {:error, "unsupported method TRACE"} =
             HTTP.request(%{"url" => "http://a.b", "method" => "trace"})

    assert {:error, "body must be a string"} =
             HTTP.request(%{"url" => "http://a.b", "body" => %{}})

    assert {:error, "headers must be" <> _} =
             HTTP.request(%{"url" => "http://a.b", "headers" => %{"a" => %{}}})
  end
end
