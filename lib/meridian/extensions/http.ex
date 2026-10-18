defmodule Meridian.Extensions.HTTP do
  @moduledoc """
  Outbound HTTP for scripts (`meridian.http.request`): one plain request, the whole response
  back as data.

  Scripts are written by users, so a request may only reach public addresses. The host is
  resolved here, every address it resolves to is checked, and the connection goes to the
  checked address (so DNS can't answer differently in between). Redirects are followed by
  hand, each hop checked the same way.

  This uses Mint (what Req runs on) directly: Req resolves the host itself and can only be
  pointed at an address by starting a new connection pool per host.
  """

  @methods ~w(GET HEAD POST PUT PATCH DELETE OPTIONS)
  @redirects [301, 302, 303, 307, 308]
  @max_redirects 5

  # Headers that would leak to another host on a redirect.
  @credentials ~w(authorization cookie proxy-authorization)

  @type response :: %{String.t() => term()}

  @doc """
  Makes a request (`"method"`, `"url"`, `"headers"`, `"body"`) and returns `"status"`,
  `"headers"` (lowercase names) and `"body"`. A body over `:max_body_bytes` is cut there and
  the response gets `"truncated" => true`.

  Options: `:timeout` (the whole request, redirects included), `:max_body_bytes`, and
  `:allow_local` (skips the address check; for tests against a local server).
  """
  @spec request(map(), keyword()) :: {:ok, response()} | {:error, String.t()}
  def request(request, opts \\ []) do
    opts = Keyword.merge([timeout: 15_000, max_body_bytes: 2_000_000, allow_local: false], opts)
    deadline = System.monotonic_time(:millisecond) + opts[:timeout]

    with {:ok, method} <- method(request["method"]),
         {:ok, headers} <- headers(request["headers"]),
         {:ok, body} <- body(request["body"]),
         {:ok, uri} <- parse_url(request["url"]) do
      follow(method, uri, headers, body, deadline, opts, @max_redirects)
    end
  end

  defp method(nil), do: {:ok, "GET"}

  defp method(method) when is_binary(method) do
    method = String.upcase(method)
    if method in @methods, do: {:ok, method}, else: {:error, "unsupported method #{method}"}
  end

  defp method(_method), do: {:error, "method must be a string"}

  defp headers(nil), do: {:ok, []}

  defp headers(headers) when is_map(headers) do
    Enum.reduce_while(headers, {:ok, []}, fn
      {name, value}, {:ok, acc} when is_binary(name) and (is_binary(value) or is_number(value)) ->
        name = String.downcase(name)
        # The host is the URL's; the length is the body's.
        if name in ["host", "content-length"],
          do: {:cont, {:ok, acc}},
          else: {:cont, {:ok, [{name, to_string(value)} | acc]}}

      _header, _acc ->
        {:halt, {:error, "headers must be a table of names and string values"}}
    end)
  end

  defp headers(_headers), do: {:error, "headers must be a table of names and string values"}

  defp body(body) when is_binary(body) or is_nil(body), do: {:ok, body}
  defp body(_body), do: {:error, "body must be a string"}

  defp parse_url(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host} = uri}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, uri}

      {:ok, _uri} ->
        {:error, "only http and https URLs are allowed"}

      {:error, _} ->
        {:error, "invalid URL"}
    end
  end

  defp parse_url(_url), do: {:error, "url must be a string"}

  defp follow(method, uri, headers, body, deadline, opts, redirects_left) do
    with {:ok, address} <- resolve(uri.host, opts[:allow_local]),
         {:ok, response} <- send_request(method, uri, address, headers, body, deadline, opts) do
      location = header(response, "location")

      cond do
        response["status"] not in @redirects or location == nil ->
          {:ok, response}

        redirects_left == 0 ->
          {:error, "too many redirects"}

        true ->
          with {:ok, next} <- parse_url(URI.merge(uri, location) |> URI.to_string()) do
            {method, body} = redirected_method(response["status"], method, body)
            headers = if next.host == uri.host, do: headers, else: drop_credentials(headers)
            follow(method, next, headers, body, deadline, opts, redirects_left - 1)
          end
      end
    end
  end

  # 307 and 308 repeat the request; the others turn it into a GET, as browsers do.
  defp redirected_method(status, method, body) when status in [307, 308], do: {method, body}
  defp redirected_method(_status, "HEAD", _body), do: {"HEAD", nil}
  defp redirected_method(_status, _method, _body), do: {"GET", nil}

  defp drop_credentials(headers),
    do: Enum.reject(headers, fn {name, _} -> name in @credentials end)

  defp header(response, name) do
    response["headers"][name]
  end

  ## Addresses

  # An address to connect to, if every address the host has is public.
  defp resolve(host, allow_local) do
    host = host |> String.trim_leading("[") |> String.trim_trailing("]")

    addresses =
      case :inet.parse_address(String.to_charlist(host)) do
        {:ok, address} ->
          [address]

        {:error, _} ->
          for family <- [:inet, :inet6],
              {:ok, addresses} <- [:inet.getaddrs(String.to_charlist(host), family)],
              address <- addresses,
              do: address
      end

    cond do
      addresses == [] -> {:error, "couldn't resolve #{host}"}
      allow_local or Enum.all?(addresses, &public?/1) -> {:ok, hd(addresses)}
      true -> {:error, "#{host} is a private or reserved address"}
    end
  end

  @doc "Whether an IP address is on the public internet."
  @spec public?(:inet.ip_address()) :: boolean()
  def public?({0, _, _, _}), do: false
  def public?({10, _, _, _}), do: false
  def public?({100, b, _, _}) when b in 64..127, do: false
  def public?({127, _, _, _}), do: false
  def public?({169, 254, _, _}), do: false
  def public?({172, b, _, _}) when b in 16..31, do: false
  def public?({192, 0, 0, _}), do: false
  def public?({192, 168, _, _}), do: false
  def public?({198, b, _, _}) when b in 18..19, do: false
  def public?({a, _, _, _}) when a >= 224, do: false
  def public?({_, _, _, _}), do: true
  # IPv4-mapped (::ffff:a.b.c.d) and NAT64 (64:ff9b::a.b.c.d) addresses are IPv4 addresses.
  def public?({0, 0, 0, 0, 0, 0xFFFF, ab, cd}), do: public?(ipv4(ab, cd))
  def public?({0x64, 0xFF9B, 0, 0, 0, 0, ab, cd}), do: public?(ipv4(ab, cd))
  def public?({0, 0, 0, 0, 0, 0, 0, _}), do: false
  def public?({a, _, _, _, _, _, _, _}) when a in 0xFC00..0xFDFF, do: false
  def public?({a, _, _, _, _, _, _, _}) when a in 0xFE80..0xFEBF, do: false
  def public?({a, _, _, _, _, _, _, _}) when a >= 0xFF00, do: false
  def public?({_, _, _, _, _, _, _, _}), do: true

  defp ipv4(ab, cd), do: {div(ab, 256), rem(ab, 256), div(cd, 256), rem(cd, 256)}

  ## The request

  defp send_request(method, uri, address, headers, body, deadline, opts) do
    scheme = String.to_existing_atom(uri.scheme)
    path = (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")

    connect_opts = [
      hostname: uri.host,
      mode: :passive,
      protocols: [:http1],
      transport_opts: [timeout: max(remaining(deadline), 1)]
    ]

    with {:ok, conn} <- wrap(Mint.HTTP.connect(scheme, address, uri.port, connect_opts)) do
      result =
        with {:ok, conn, ref} <- wrap(Mint.HTTP.request(conn, method, path, headers, body)) do
          receive_response(conn, ref, %{"body" => []}, 0, deadline, opts[:max_body_bytes])
        end

      Mint.HTTP.close(conn)
      result
    end
  end

  defp receive_response(conn, ref, response, size, deadline, max) do
    case remaining(deadline) do
      0 ->
        {:error, "timed out"}

      timeout ->
        with {:ok, conn, parts} <- wrap(Mint.HTTP.recv(conn, 0, timeout)) do
          case Enum.reduce_while(parts, {response, size}, &add_part(&1, &2, ref, max)) do
            {:done, response} -> {:ok, finish(response)}
            {response, size} -> receive_response(conn, ref, response, size, deadline, max)
          end
        end
    end
  end

  defp add_part({:status, ref, status}, {response, size}, ref, _max),
    do: {:cont, {Map.put(response, "status", status), size}}

  defp add_part({:headers, ref, headers}, {response, size}, ref, _max),
    do: {:cont, {Map.put(response, "headers", headers), size}}

  defp add_part({:data, ref, data}, {response, size}, ref, max) do
    if size + byte_size(data) > max do
      data = binary_part(data, 0, max - size)
      {:halt, {:done, response |> add_data(data) |> Map.put("truncated", true)}}
    else
      {:cont, {add_data(response, data), size + byte_size(data)}}
    end
  end

  defp add_part({:done, ref}, {response, _size}, ref, _max), do: {:halt, {:done, response}}
  defp add_part({:error, ref, reason}, _acc, ref, _max), do: {:halt, {:done, {:error, reason}}}
  defp add_part(_part, acc, _ref, _max), do: {:cont, acc}

  defp add_data(response, data), do: Map.update!(response, "body", &[&1, data])

  defp finish({:error, reason}), do: {:error, describe(reason)}

  defp finish(response) do
    headers =
      response
      |> Map.get("headers", [])
      |> Enum.group_by(fn {name, _} -> String.downcase(name) end, fn {_, value} -> value end)
      |> Map.new(fn {name, values} -> {name, Enum.join(values, ", ")} end)

    %{response | "body" => IO.iodata_to_binary(response["body"])}
    |> Map.put("headers", headers)
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  # Mint's errors (also returned with the connection) as one message.
  defp wrap({:error, reason}), do: {:error, describe(reason)}
  defp wrap({:error, _conn, reason}), do: {:error, describe(reason)}
  defp wrap({:error, _conn, reason, _responses}), do: {:error, describe(reason)}
  defp wrap(ok), do: ok

  defp describe(%{reason: :timeout}), do: "timed out"
  defp describe(%{__exception__: true} = error), do: Exception.message(error)
  defp describe(reason), do: inspect(reason)
end
