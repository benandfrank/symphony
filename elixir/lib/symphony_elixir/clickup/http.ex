defmodule SymphonyElixir.ClickUp.HTTP do
  @moduledoc """
  Default HTTP transport for ClickUp REST API calls.

  Isolated from `ClickUp.Client` so that the pure logic in `Client` can reach
  full test coverage via injected `request_fun` without needing network access.

  ## Timeouts

  Two independent timeouts are set on every request:

  - **connect timeout** (`connect_options: [timeout: #{div(30_000, 1_000)}s]`) — maximum time
    allowed to establish the TCP connection to the ClickUp API.
  - **receive timeout** (`receive_timeout: #{div(30_000, 1_000)}s`) — maximum time allowed for
    the server to send the response headers after the connection is open. Without this a server
    that accepts the connection but then stalls will block the caller indefinitely, including
    the sequential pagination loop in `ClickUp.Client` and any `Task.async_stream` that wraps
    individual task fetches.

  Both timeouts are well below the `Task.async_stream` timeout configured in `ClickUp.Client` so
  that a hung request is cut by Req before the BEAM cancels the task wrapping the request.
  """

  @connect_timeout_ms 30_000
  @receive_timeout_ms 30_000

  @doc false
  @spec build_req_opts(atom(), String.t(), list(), map() | nil) :: keyword()
  def build_req_opts(method, url, headers, body) do
    req_opts = [
      method: method,
      url: url,
      headers: headers,
      connect_options: [timeout: @connect_timeout_ms],
      receive_timeout: @receive_timeout_ms
    ]

    if body do
      Keyword.put(req_opts, :json, body)
    else
      req_opts
    end
  end

  @spec request(atom(), String.t(), [{String.t(), String.t()}], map() | nil) ::
          {:ok, Req.Response.t()} | {:error, term()}
  def request(method, url, headers, body) do
    Req.request(build_req_opts(method, url, headers, body))
  end
end
