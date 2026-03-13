defmodule SymphonyElixir.Tracker.Retry do
  @moduledoc """
  Bounded retry helper for tracker HTTP 429 (rate limit) responses.

  Honors `Retry-After` response headers when present and parseable.
  Falls back to bounded exponential backoff otherwise.

  Only retries on HTTP 429 — all other responses and transport errors
  are returned immediately, preserving the caller's existing error semantics.
  """

  require Logger

  @default_max_attempts 3
  @default_base_backoff_ms 1_000
  @default_max_backoff_ms 30_000

  @typedoc "Any term returned by the wrapped request function."
  @type response :: term()

  @doc """
  Executes `request_fun` with bounded 429 retry/backoff.

  ## Options

  - `:max_attempts` — total attempts including the first try (default: `3`)
  - `:base_backoff_ms` — base delay in ms for exponential backoff (default: `1_000`)
  - `:max_backoff_ms` — delay cap in ms (default: `30_000`)
  - `:sleep_fun` — injectable `(ms :: integer() -> any())` for testing (default: `Process.sleep/1`)
  - `:caller` — string label used in log messages (default: `"tracker"`)
  """
  @spec with_rate_limit_retry((-> response()), keyword()) :: response()
  def with_rate_limit_retry(request_fun, opts \\ []) do
    max_attempts = Keyword.get(opts, :max_attempts, @default_max_attempts)
    base_backoff_ms = Keyword.get(opts, :base_backoff_ms, @default_base_backoff_ms)
    max_backoff_ms = Keyword.get(opts, :max_backoff_ms, @default_max_backoff_ms)
    sleep_fun = Keyword.get(opts, :sleep_fun, &Process.sleep/1)
    caller = Keyword.get(opts, :caller, "tracker")

    do_retry(request_fun, sleep_fun, caller, 1, max_attempts, base_backoff_ms, max_backoff_ms)
  end

  @doc false
  @spec parse_retry_after_header(map() | [{String.t(), String.t()}] | term()) :: integer() | nil
  def parse_retry_after_header(headers) when is_map(headers) do
    value = find_header_value_in_map(headers, "retry-after")
    parse_retry_after_value(value)
  end

  def parse_retry_after_header(headers) when is_list(headers) do
    value = find_header_value_in_list(headers, "retry-after")
    parse_retry_after_value(value)
  end

  def parse_retry_after_header(_headers), do: nil

  @doc false
  @spec backoff_ms(integer(), integer(), integer()) :: integer()
  def backoff_ms(attempt, base_backoff_ms, max_backoff_ms) do
    # attempt is 1-based:
    #   attempt 1 → base * 2^0 = base
    #   attempt 2 → base * 2^1 = base * 2
    min(base_backoff_ms * Integer.pow(2, attempt - 1), max_backoff_ms)
  end

  # -- Private --

  defp do_retry(request_fun, sleep_fun, caller, attempt, max_attempts, base_backoff_ms, max_backoff_ms) do
    result = request_fun.()

    if rate_limited?(result) and attempt < max_attempts do
      {delay_ms, source} = choose_delay(result, attempt, base_backoff_ms, max_backoff_ms)

      Logger.info(
        "#{caller} rate limited (429), retrying " <>
          "attempt=#{attempt + 1}/#{max_attempts} delay_ms=#{delay_ms} delay_source=#{source}"
      )

      sleep_fun.(delay_ms)
      do_retry(request_fun, sleep_fun, caller, attempt + 1, max_attempts, base_backoff_ms, max_backoff_ms)
    else
      result
    end
  end

  defp rate_limited?({:ok, %{status: 429}}), do: true
  defp rate_limited?(_), do: false

  defp choose_delay(result, attempt, base_backoff_ms, max_backoff_ms) do
    headers = extract_headers(result)
    retry_after = parse_retry_after_header(headers)

    if retry_after do
      {retry_after, :retry_after_header}
    else
      {backoff_ms(attempt, base_backoff_ms, max_backoff_ms), :exponential_backoff}
    end
  end

  @doc false
  @spec extract_headers(term()) :: map()
  def extract_headers({:ok, response}) when is_map(response) do
    Map.get(response, :headers, %{})
  end

  def extract_headers(_), do: %{}

  defp find_header_value_in_map(headers, name) when is_map(headers) do
    Enum.find_value(headers, fn {k, v} ->
      if is_binary(k) and String.downcase(k) == name, do: v, else: nil
    end)
  end

  defp find_header_value_in_list(headers, name) when is_list(headers) do
    Enum.find_value(headers, fn
      {k, v} when is_binary(k) ->
        if String.downcase(k) == name, do: v, else: nil

      _ ->
        nil
    end)
  end

  defp parse_retry_after_value([value | _]) when is_binary(value), do: parse_seconds(value)
  defp parse_retry_after_value(value) when is_binary(value), do: parse_seconds(value)
  defp parse_retry_after_value(_), do: nil

  defp parse_seconds(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} when n > 0 -> n * 1_000
      _ -> nil
    end
  end
end
