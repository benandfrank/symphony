defmodule SymphonyElixir.Codex.DynamicToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool

  test "tool_specs advertises linear_graphql for linear tracker" do
    # Arrange
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")

    # Act / Assert
    assert [
             %{
               "description" => description,
               "inputSchema" => %{
                 "properties" => %{
                   "query" => _,
                   "variables" => _
                 },
                 "required" => ["query"],
                 "type" => "object"
               },
               "name" => "linear_graphql"
             }
           ] = DynamicTool.tool_specs()

    assert description =~ "Linear"
  end

  test "tool_specs advertises clickup_api for clickup tracker" do
    # Arrange
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "clickup",
      tracker_api_token: "ck_test",
      tracker_list_id: "list-1",
      tracker_project_slug: nil
    )

    # Act / Assert
    assert [
             %{
               "description" => description,
               "inputSchema" => %{
                 "properties" => %{
                   "body" => _,
                   "method" => _,
                   "path" => _
                 },
                 "required" => ["method", "path"],
                 "type" => "object"
               },
               "name" => "clickup_api"
             }
           ] = DynamicTool.tool_specs()

    assert description =~ "ClickUp"
  end

  test "tool_specs returns an empty list for memory tracker" do
    # Arrange
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    # Act
    specs = DynamicTool.tool_specs()

    # Assert
    assert specs == []
  end

  test "unsupported tools return a failure payload with the supported tool list" do
    response = DynamicTool.execute("not_a_real_tool", %{})

    assert response["success"] == false

    assert [
             %{
               "type" => "inputText",
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => ~s(Unsupported dynamic tool: "not_a_real_tool".),
               "supportedTools" => ["linear_graphql"]
             }
           }
  end

  test "linear_graphql returns successful GraphQL responses as tool text" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "query Viewer { viewer { id } }",
          "variables" => %{"includeTeams" => false}
        },
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_123"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{"includeTeams" => false}, []}

    assert response["success"] == true

    assert [
             %{
               "type" => "inputText",
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{"data" => %{"viewer" => %{"id" => "usr_123"}}}
  end

  test "linear_graphql accepts a raw GraphQL query string" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        "  query Viewer { viewer { id } }  ",
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_456"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql ignores legacy operationName arguments" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "operationName" => "Viewer"},
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_789"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql passes multi-operation documents through unchanged" do
    test_pid = self()

    query = """
    query Viewer { viewer { id } }
    query Teams { teams { nodes { id } } }
    """

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => query},
        linear_client: fn forwarded_query, variables, opts ->
          send(test_pid, {:linear_client_called, forwarded_query, variables, opts})
          {:ok, %{"errors" => [%{"message" => "Must provide operation name if query contains multiple operations."}]}}
        end
      )

    assert_received {:linear_client_called, forwarded_query, %{}, []}
    assert forwarded_query == String.trim(query)
    assert response["success"] == false
  end

  test "linear_graphql rejects blank raw query strings even when using the default client" do
    response = DynamicTool.execute("linear_graphql", "   ")

    assert response["success"] == false

    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }
  end

  test "linear_graphql marks GraphQL error responses as failures while preserving the body" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "mutation BadMutation { nope }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{"errors" => [%{"message" => "Unknown field `nope`"}], "data" => nil}}
        end
      )

    assert response["success"] == false

    assert [
             %{
               "type" => "inputText",
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "data" => nil,
             "errors" => [%{"message" => "Unknown field `nope`"}]
           }
  end

  test "linear_graphql marks atom-key GraphQL error responses as failures" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{errors: [%{message: "boom"}], data: nil}}
        end
      )

    assert response["success"] == false
  end

  test "linear_graphql validates required arguments before calling Linear" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"variables" => %{"commentId" => "comment-1"}},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert [
             %{
               "type" => "inputText",
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }

    blank_query =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "   "},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when the query is blank")
        end
      )

    assert blank_query["success"] == false
  end

  test "linear_graphql rejects invalid argument types" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        [:not, :valid],
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
             }
           }
  end

  test "linear_graphql rejects invalid variables" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "variables" => ["bad"]},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when variables are invalid")
        end
      )

    assert response["success"] == false

    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "`linear_graphql.variables` must be a JSON object when provided."
             }
           }
  end

  test "linear_graphql formats transport and auth failures" do
    missing_token =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :missing_linear_api_token} end
      )

    assert missing_token["success"] == false

    assert [
             %{
               "text" => missing_token_text
             }
           ] = missing_token["contentItems"]

    assert Jason.decode!(missing_token_text) == %{
             "error" => %{
               "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
             }
           }

    status_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_status, 503}} end
      )

    assert [
             %{
               "text" => status_error_text
             }
           ] = status_error["contentItems"]

    assert Jason.decode!(status_error_text) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed with HTTP 503.",
               "status" => 503
             }
           }

    request_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_request, :timeout}} end
      )

    assert [
             %{
               "text" => request_error_text
             }
           ] = request_error["contentItems"]

    assert Jason.decode!(request_error_text) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed before receiving a successful response.",
               "reason" => ":timeout"
             }
           }
  end

  test "linear_graphql formats unexpected failures from the client" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :boom} end
      )

    assert response["success"] == false

    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{
             "error" => %{
               "message" => "Linear GraphQL tool execution failed.",
               "reason" => ":boom"
             }
           }
  end

  test "linear_graphql falls back to inspect for non-JSON payloads" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:ok, :ok} end
      )

    assert response["success"] == true

    assert [
             %{
               "text" => ":ok"
             }
           ] = response["contentItems"]
  end

  test "clickup_api executes a guarded request and returns structured output" do
    # Arrange
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "clickup",
      tracker_api_token: "ck_test",
      tracker_list_id: "list-1",
      tracker_project_slug: nil
    )

    # Act
    response =
      DynamicTool.execute(
        "clickup_api",
        %{"method" => "POST", "path" => "/task/task-1/comment", "body" => %{"comment_text" => "hello"}},
        clickup_client: fn method, path, body, opts ->
          assert {method, path, body, opts} == {"POST", "/task/task-1/comment", %{"comment_text" => "hello"}, []}
          {:ok, %{"id" => "comment-1"}}
        end
      )

    # Assert
    assert response["success"] == true

    assert [
             %{
               "text" => text
             }
           ] = response["contentItems"]

    assert Jason.decode!(text) == %{"id" => "comment-1"}
  end

  test "clickup_api rejects disallowed methods" do
    # Arrange
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "clickup")

    # Act
    response = DynamicTool.execute("clickup_api", %{"method" => "DELETE", "path" => "/task/task-1"})

    # Assert
    assert response["success"] == false

    assert Jason.decode!(hd(response["contentItems"])["text"]) == %{
             "error" => %{"message" => "`clickup_api.method` must be one of: GET, POST, PUT."}
           }
  end

  test "clickup_api rejects paths outside allowlist" do
    # Arrange
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "clickup")

    # Act
    response = DynamicTool.execute("clickup_api", %{"method" => "GET", "path" => "/user/me"})

    # Assert
    assert response["success"] == false

    assert Jason.decode!(hd(response["contentItems"])["text"]) == %{
             "error" => %{"message" => "`clickup_api.path` is not allowed. Allowed prefixes: /task/, /list/, /team/."}
           }
  end

  test "clickup_api rejects GET requests with body" do
    # Arrange
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "clickup")

    # Act
    response = DynamicTool.execute("clickup_api", %{"method" => "GET", "path" => "/task/task-1", "body" => %{"x" => 1}})

    # Assert
    assert response["success"] == false

    assert Jason.decode!(hd(response["contentItems"])["text"]) == %{
             "error" => %{"message" => "`clickup_api.body` is not allowed for GET requests."}
           }
  end

  test "clickup_api redacts transport errors" do
    # Arrange
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "clickup")

    # Act
    response =
      DynamicTool.execute(
        "clickup_api",
        %{"method" => "GET", "path" => "/task/task-1"},
        clickup_client: fn _method, _path, _body, _opts ->
          {:error, {:clickup_api_request, {:tls_alert, "secret-token-leak"}}}
        end
      )

    # Assert
    assert response["success"] == false

    assert Jason.decode!(hd(response["contentItems"])["text"]) == %{
             "error" => %{
               "message" => "ClickUp API request failed before receiving a successful response.",
               "reason" => "transport_error"
             }
           }
  end

  test "unsupported tools include current tracker supported tool list" do
    # Arrange
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "clickup")

    # Act
    response = DynamicTool.execute("linear_graphql", %{})

    # Assert
    assert response["success"] == false

    assert Jason.decode!(hd(response["contentItems"])["text"]) == %{
             "error" => %{
               "message" => ~s(Unsupported dynamic tool: "linear_graphql".),
               "supportedTools" => ["clickup_api"]
             }
           }
  end

  test "execute returns a clear error when tracker_kind is nil" do
    # Arrange
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: nil)

    # Act
    response = DynamicTool.execute("clickup_api", %{"method" => "GET", "path" => "/task/t1"})

    # Assert
    assert response["success"] == false

    assert Jason.decode!(hd(response["contentItems"])["text"]) == %{
             "error" => %{
               "message" => "Tracker not configured. Set `tracker.kind` in `WORKFLOW.md`.",
               "supportedTools" => []
             }
           }
  end

  test "clickup_api rejects non-map arguments" do
    # Arrange
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "clickup")

    # Act
    response = DynamicTool.execute("clickup_api", "not a map")

    # Assert
    assert response["success"] == false

    assert Jason.decode!(hd(response["contentItems"])["text"]) == %{
             "error" => %{
               "message" => "`clickup_api` expects an object with required `method` and `path`, plus optional `body`."
             }
           }
  end

  test "clickup_api rejects missing method" do
    # Arrange
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "clickup")

    # Act
    response = DynamicTool.execute("clickup_api", %{"path" => "/task/task-1"})

    # Assert
    assert response["success"] == false

    assert Jason.decode!(hd(response["contentItems"])["text"]) == %{
             "error" => %{
               "message" => "`clickup_api.method` is required. Allowed values: GET, POST, PUT."
             }
           }
  end

  test "clickup_api rejects missing path" do
    # Arrange
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "clickup")

    # Act
    response = DynamicTool.execute("clickup_api", %{"method" => "GET"})

    # Assert
    assert response["success"] == false

    assert Jason.decode!(hd(response["contentItems"])["text"]) == %{
             "error" => %{
               "message" => "`clickup_api.path` is required and must be non-empty."
             }
           }
  end

  test "clickup_api rejects non-map body" do
    # Arrange
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "clickup")

    # Act
    response = DynamicTool.execute("clickup_api", %{"method" => "POST", "path" => "/task/task-1", "body" => "string"})

    # Assert
    assert response["success"] == false

    assert Jason.decode!(hd(response["contentItems"])["text"]) == %{
             "error" => %{
               "message" => "`clickup_api.body` must be a JSON object when provided."
             }
           }
  end

  test "clickup_api rejects oversized request body" do
    # Arrange
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "clickup")
    large_body = %{"data" => String.duplicate("x", 11_000)}

    # Act
    response = DynamicTool.execute("clickup_api", %{"method" => "POST", "path" => "/task/task-1", "body" => large_body})

    # Assert
    assert response["success"] == false

    assert Jason.decode!(hd(response["contentItems"])["text"]) == %{
             "error" => %{
               "message" => "`clickup_api.body` exceeds size limit."
             }
           }
  end

  test "clickup_api rejects oversized response" do
    # Arrange
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "clickup")

    # Act
    response =
      DynamicTool.execute(
        "clickup_api",
        %{"method" => "GET", "path" => "/task/task-1"},
        clickup_client: fn _m, _p, _b, _o ->
          {:ok, %{"data" => String.duplicate("x", 51_000)}}
        end
      )

    # Assert
    assert response["success"] == false

    assert Jason.decode!(hd(response["contentItems"])["text"]) == %{
             "error" => %{
               "message" => "`clickup_api` response exceeds size limit."
             }
           }
  end

  test "clickup_api surfaces missing tracker auth" do
    # Arrange
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "clickup")

    # Act
    response =
      DynamicTool.execute(
        "clickup_api",
        %{"method" => "GET", "path" => "/task/task-1"},
        clickup_client: fn _m, _p, _b, _o ->
          {:error, :missing_tracker_api_token}
        end
      )

    # Assert
    assert response["success"] == false

    assert Jason.decode!(hd(response["contentItems"])["text"]) == %{
             "error" => %{
               "message" => "Symphony is missing tracker auth. Set `tracker.api_key` in `WORKFLOW.md` or export the tracker API key env var."
             }
           }
  end

  test "clickup_api surfaces HTTP status errors" do
    # Arrange
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "clickup")

    # Act
    response =
      DynamicTool.execute(
        "clickup_api",
        %{"method" => "GET", "path" => "/task/task-1"},
        clickup_client: fn _m, _p, _b, _o ->
          {:error, {:clickup_api_status, 429}}
        end
      )

    # Assert
    assert response["success"] == false

    assert Jason.decode!(hd(response["contentItems"])["text"]) == %{
             "error" => %{
               "message" => "ClickUp API request failed with HTTP 429.",
               "status" => 429
             }
           }
  end

  test "clickup_api redacts unknown error reasons" do
    # Arrange
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "clickup")

    # Act
    response =
      DynamicTool.execute(
        "clickup_api",
        %{"method" => "GET", "path" => "/task/task-1"},
        clickup_client: fn _m, _p, _b, _o ->
          {:error, :something_unexpected}
        end
      )

    # Assert
    assert response["success"] == false

    assert Jason.decode!(hd(response["contentItems"])["text"]) == %{
             "error" => %{
               "message" => "ClickUp API tool execution failed.",
               "reason" => "redacted"
             }
           }
  end
end
