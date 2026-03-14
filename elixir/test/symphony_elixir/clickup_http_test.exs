defmodule SymphonyElixir.ClickUp.HTTPTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ClickUp.HTTP

  # The problem: ClickUp.HTTP previously only set a TCP connect timeout.
  # A server that accepts the connection but then stalls sending the response
  # body will hang the caller forever — blocking the sequential pagination
  # loop in ClickUp.Client and any Task.async_stream that wraps it.
  #
  # The solution: expose build_req_opts/4 as a testable pure function and
  # add receive_timeout so Req cuts the request short if the server stalls
  # after the connection is established.

  describe "build_req_opts/4" do
    test "sets connect_options timeout to guard against hung TCP connections" do
      # Arrange
      url = "https://api.clickup.com/api/v2/list/123/task"

      # Act
      opts = HTTP.build_req_opts(:get, url, [], nil)

      # Assert
      assert connect_opts = opts[:connect_options]
      assert is_integer(connect_opts[:timeout])
      assert connect_opts[:timeout] > 0
    end

    test "sets receive_timeout to guard against stalled response bodies" do
      # Arrange
      url = "https://api.clickup.com/api/v2/list/123/task"

      # Act
      opts = HTTP.build_req_opts(:get, url, [], nil)

      # Assert
      assert is_integer(opts[:receive_timeout]),
             "expected receive_timeout to be set; without it a server that accepts the " <>
               "connection but stalls sending headers will block the caller indefinitely"

      assert opts[:receive_timeout] > 0
    end

    test "connect timeout and receive timeout are both within a reasonable bound" do
      # Arrange
      url = "https://api.clickup.com/api/v2/task/abc"

      # Act
      opts = HTTP.build_req_opts(:get, url, [], nil)

      # Assert — each timeout individually must be ≤ 60s so that
      # Task.async_stream (capped at 2 × connect_timeout_ms) can actually
      # kill a stuck task before the beam scheduler notices
      assert opts[:connect_options][:timeout] <= 60_000
      assert opts[:receive_timeout] <= 60_000
    end

    test "omits :json key for bodyless requests so Req does not send a content-type header" do
      # Arrange
      url = "https://api.clickup.com/api/v2/task/abc"

      # Act
      opts = HTTP.build_req_opts(:get, url, [], nil)

      # Assert
      refute Keyword.has_key?(opts, :json)
    end

    test "includes :json body for write requests" do
      # Arrange
      url = "https://api.clickup.com/api/v2/task/abc/comment"
      body = %{"comment_text" => "## Workpad\n\nStarting."}

      # Act
      opts = HTTP.build_req_opts(:post, url, [], body)

      # Assert
      assert opts[:json] == body
    end

    test "forwards custom headers unchanged" do
      # Arrange
      url = "https://api.clickup.com/api/v2/task/abc"
      headers = [{"Authorization", "ck_test_token"}, {"Content-Type", "application/json"}]

      # Act
      opts = HTTP.build_req_opts(:get, url, headers, nil)

      # Assert
      assert opts[:headers] == headers
    end
  end
end
