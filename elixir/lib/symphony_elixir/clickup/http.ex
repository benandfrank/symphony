defmodule SymphonyElixir.ClickUp.HTTP do
  @moduledoc """
  Default HTTP transport for ClickUp REST API calls.

  Isolated from `ClickUp.Client` so that the pure logic in `Client` can reach
  full test coverage via injected `request_fun` without needing network access.
  """

  @connect_timeout_ms 30_000

  @spec request(atom(), String.t(), [{String.t(), String.t()}], map() | nil) ::
          {:ok, Req.Response.t()} | {:error, term()}
  def request(method, url, headers, body) do
    req_opts = [
      method: method,
      url: url,
      headers: headers,
      connect_options: [timeout: @connect_timeout_ms]
    ]

    req_opts =
      if body do
        Keyword.put(req_opts, :json, body)
      else
        req_opts
      end

    Req.request(req_opts)
  end
end
