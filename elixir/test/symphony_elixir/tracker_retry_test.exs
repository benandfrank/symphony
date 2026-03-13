defmodule SymphonyElixir.Tracker.RetryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Tracker.Retry

  describe "with_rate_limit_retry/2" do
    test "returns the response immediately when not rate limited" do
      # Arrange
      calls = :counters.new(1, [:atomics])

      request_fun = fn ->
        :counters.add(calls, 1, 1)
        {:ok, %{status: 200, body: %{"ok" => true}}}
      end

      # Act
      result = Retry.with_rate_limit_retry(request_fun, sleep_fun: fn _ms -> :ok end)

      # Assert
      assert {:ok, %{status: 200}} = result
      assert :counters.get(calls, 1) == 1
    end

    test "uses default opts when called without options (no rate limit means no sleep)" do
      # Arrange — non-429 response: default sleep_fun (Process.sleep) is never called
      request_fun = fn -> {:ok, %{status: 200, body: %{}}} end

      # Act — called with no opts; covers the default-argument function head
      result = Retry.with_rate_limit_retry(request_fun)

      # Assert
      assert {:ok, %{status: 200}} = result
    end

    test "retries once after 429 and returns success on the next attempt" do
      # Arrange
      responses = Agent.start_link(fn -> [:rate_limited, :ok] end) |> then(fn {:ok, pid} -> pid end)

      request_fun = fn ->
        Agent.get_and_update(responses, fn [h | t] -> {h, t} end)
        |> case do
          :rate_limited -> {:ok, %{status: 429, body: %{}}}
          :ok -> {:ok, %{status: 200, body: %{"result" => "success"}}}
        end
      end

      recorded_delays = :ets.new(:delays, [:bag, :public])

      sleep_fun = fn ms ->
        :ets.insert(recorded_delays, {:delay, ms})
        :ok
      end

      # Act
      result =
        Retry.with_rate_limit_retry(request_fun,
          sleep_fun: sleep_fun,
          base_backoff_ms: 500,
          max_backoff_ms: 10_000
        )

      # Assert
      assert {:ok, %{status: 200, body: %{"result" => "success"}}} = result
      assert [{:delay, 500}] = :ets.lookup(recorded_delays, :delay)
    end

    test "honors Retry-After header when present and parseable" do
      # Arrange
      responses = Agent.start_link(fn -> [:rate_limited, :ok] end) |> then(fn {:ok, pid} -> pid end)

      request_fun = fn ->
        Agent.get_and_update(responses, fn [h | t] -> {h, t} end)
        |> case do
          :rate_limited ->
            {:ok, %{status: 429, body: %{}, headers: %{"retry-after" => ["3"]}}}

          :ok ->
            {:ok, %{status: 200, body: %{}}}
        end
      end

      recorded_delays = :ets.new(:delays_header, [:bag, :public])

      sleep_fun = fn ms ->
        :ets.insert(recorded_delays, {:delay, ms})
        :ok
      end

      # Act
      Retry.with_rate_limit_retry(request_fun, sleep_fun: sleep_fun, base_backoff_ms: 1_000)

      # Assert — delay should be 3_000 ms (from Retry-After: 3), not base_backoff_ms
      assert [{:delay, 3_000}] = :ets.lookup(recorded_delays, :delay)
    end

    test "uses exponential backoff when Retry-After header is absent" do
      # Arrange
      responses = Agent.start_link(fn -> [:rl, :rl, :ok] end) |> then(fn {:ok, pid} -> pid end)

      request_fun = fn ->
        Agent.get_and_update(responses, fn [h | t] -> {h, t} end)
        |> case do
          :rl -> {:ok, %{status: 429, body: %{}}}
          :ok -> {:ok, %{status: 200, body: %{}}}
        end
      end

      recorded_delays = :ets.new(:delays_backoff, [:bag, :public])

      sleep_fun = fn ms ->
        :ets.insert(recorded_delays, {:delay, ms})
        :ok
      end

      # Act
      Retry.with_rate_limit_retry(request_fun,
        sleep_fun: sleep_fun,
        max_attempts: 3,
        base_backoff_ms: 100,
        max_backoff_ms: 10_000
      )

      # Assert — attempt 1 delay: 100ms, attempt 2 delay: 200ms
      delays = :ets.lookup(recorded_delays, :delay) |> Enum.map(fn {:delay, ms} -> ms end) |> Enum.sort()
      assert delays == [100, 200]
    end

    test "returns final 429 error response after max attempts are exhausted" do
      # Arrange
      request_fun = fn -> {:ok, %{status: 429, body: %{"err" => "rate limited"}}} end

      # Act
      result =
        Retry.with_rate_limit_retry(request_fun,
          sleep_fun: fn _ms -> :ok end,
          max_attempts: 3
        )

      # Assert
      assert {:ok, %{status: 429}} = result
    end

    test "does not retry transport errors" do
      # Arrange
      calls = :counters.new(1, [:atomics])

      request_fun = fn ->
        :counters.add(calls, 1, 1)
        {:error, :econnrefused}
      end

      # Act
      result =
        Retry.with_rate_limit_retry(request_fun,
          sleep_fun: fn _ms -> :ok end,
          max_attempts: 3
        )

      # Assert
      assert {:error, :econnrefused} = result
      assert :counters.get(calls, 1) == 1
    end
  end

  describe "extract_headers/1" do
    test "returns the :headers field from a successful response map" do
      # Arrange
      response = {:ok, %{status: 429, body: %{}, headers: %{"retry-after" => ["5"]}}}

      # Act
      result = Retry.extract_headers(response)

      # Assert
      assert result == %{"retry-after" => ["5"]}
    end

    test "returns empty map when response has no :headers key" do
      # Act / Assert
      assert Retry.extract_headers({:ok, %{status: 429, body: %{}}}) == %{}
    end

    test "returns empty map for non-map responses (catch-all defensive clause)" do
      # Act / Assert — covers the safety net for future call-site changes
      assert Retry.extract_headers({:error, :timeout}) == %{}
      assert Retry.extract_headers(:unexpected) == %{}
    end
  end

  describe "parse_retry_after_header/1" do
    test "parses lowercase 'retry-after' key with list value (Req.Response style)" do
      # Arrange
      headers = %{"retry-after" => ["5"]}

      # Act
      result = Retry.parse_retry_after_header(headers)

      # Assert
      assert result == 5_000
    end

    test "parses 'Retry-After' mixed-case key with list value" do
      # Arrange
      headers = %{"Retry-After" => ["10"]}

      # Act
      result = Retry.parse_retry_after_header(headers)

      # Assert
      assert result == 10_000
    end

    test "parses list-of-tuples headers case-insensitively" do
      # Arrange — tuple-list with mixed-case header name
      headers = [{"Content-Type", "application/json"}, {"Retry-After", "7"}]

      # Act
      result = Retry.parse_retry_after_header(headers)

      # Assert
      assert result == 7_000
    end

    test "skips non-binary-key and non-tuple entries in header list" do
      # Arrange — list containing a non-{k,v} element before the real header
      headers = [:unexpected, {"Retry-After", "2"}]

      # Act
      result = Retry.parse_retry_after_header(headers)

      # Assert — the atom is skipped, real header is found
      assert result == 2_000
    end

    test "returns nil when retry-after key is absent" do
      # Arrange
      headers = %{"content-type" => ["application/json"]}

      # Act
      result = Retry.parse_retry_after_header(headers)

      # Assert
      assert result == nil
    end

    test "returns nil for zero retry-after value" do
      # Arrange
      headers = %{"retry-after" => ["0"]}

      # Act
      result = Retry.parse_retry_after_header(headers)

      # Assert — zero is not a valid positive delay
      assert result == nil
    end

    test "returns nil for negative retry-after value" do
      # Arrange
      headers = %{"retry-after" => ["-3"]}

      # Act
      result = Retry.parse_retry_after_header(headers)

      # Assert
      assert result == nil
    end

    test "returns nil for non-numeric retry-after value" do
      # Arrange
      headers = %{"retry-after" => ["soon"]}

      # Act
      result = Retry.parse_retry_after_header(headers)

      # Assert
      assert result == nil
    end

    test "returns nil for non-map, non-list input" do
      # Act / Assert
      assert Retry.parse_retry_after_header(nil) == nil
      assert Retry.parse_retry_after_header("5") == nil
    end
  end

  describe "backoff_ms/3" do
    test "attempt 1 returns base_backoff_ms" do
      # Act
      result = Retry.backoff_ms(1, 1_000, 30_000)

      # Assert
      assert result == 1_000
    end

    test "attempt 2 returns base * 2" do
      # Act
      result = Retry.backoff_ms(2, 1_000, 30_000)

      # Assert
      assert result == 2_000
    end

    test "caps at max_backoff_ms regardless of attempt number" do
      # Act
      result = Retry.backoff_ms(100, 1_000, 30_000)

      # Assert
      assert result == 30_000
    end
  end
end
