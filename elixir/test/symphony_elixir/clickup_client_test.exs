defmodule SymphonyElixir.ClickUp.ClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ClickUp.Client
  alias SymphonyElixir.Issue

  defp clickup_workflow!(opts \\ []) do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "clickup",
      tracker_api_token: Keyword.get(opts, :token, "ck_test"),
      tracker_list_id: Keyword.get(opts, :list_id, "list-900"),
      tracker_project_slug: nil
    )
  end

  describe "normalize_task/1" do
    test "normalizes a full ClickUp task payload into an Issue struct" do
      # Arrange
      task = %{
        "id" => "task-1",
        "custom_id" => "PROJ-42",
        "name" => "Fix login bug",
        "description" => "Safari broken",
        "status" => %{"status" => "In Progress"},
        "priority" => %{"id" => "2"},
        "assignees" => [%{"id" => 12_345, "username" => "jdoe"}],
        "tags" => [%{"name" => "Bug"}, %{"name" => "Frontend"}],
        "url" => "https://app.clickup.com/t/task-1",
        "date_created" => "1677000000000",
        "date_updated" => "1677100000000",
        "dependencies" => []
      }

      # Act
      issue = Client.normalize_task(task)

      # Assert
      assert %Issue{} = issue
      assert issue.id == "task-1"
      assert issue.identifier == "PROJ-42"
      assert issue.title == "Fix login bug"
      assert issue.description == "Safari broken"
      assert issue.state == "In Progress"
      assert issue.priority == 2
      assert issue.assignee_id == "12345"
      assert issue.labels == ["bug", "frontend"]
      assert issue.url == "https://app.clickup.com/t/task-1"
      assert issue.branch_name == nil
      assert issue.blocked_by == []
      assert %DateTime{} = issue.created_at
      assert %DateTime{} = issue.updated_at
    end

    test "uses id as identifier when custom_id is absent" do
      # Arrange
      task = %{
        "id" => "task-2",
        "name" => "No custom ID",
        "status" => %{"status" => "open"},
        "tags" => [],
        "dependencies" => []
      }

      # Act
      issue = Client.normalize_task(task)

      # Assert
      assert issue.identifier == "task-2"
    end

    test "handles nil priority and empty assignees" do
      # Arrange
      task = %{
        "id" => "task-3",
        "name" => "Minimal task",
        "status" => %{"status" => "todo"},
        "priority" => nil,
        "assignees" => [],
        "tags" => [],
        "dependencies" => []
      }

      # Act
      issue = Client.normalize_task(task)

      # Assert
      assert issue.priority == nil
      assert issue.assignee_id == nil
    end

    test "extracts blocked_by from dependencies with type 0 (waiting on)" do
      # Arrange — type 0 means current task is waiting on depends_on task
      task = %{
        "id" => "task-4",
        "name" => "Blocked task",
        "status" => %{"status" => "open"},
        "tags" => [],
        "dependencies" => [
          %{"task_id" => "task-4", "depends_on" => "blocker-1", "type" => 0},
          %{"task_id" => "other", "depends_on" => "task-4", "type" => 1}
        ]
      }

      # Act
      issue = Client.normalize_task(task)

      # Assert
      assert issue.blocked_by == [%{id: "blocker-1", identifier: "blocker-1", state: nil}]
    end

    test "ignores type 1 dependencies (current task blocking others)" do
      # Arrange — type 1 means current task blocks task_id task
      task = %{
        "id" => "task-5",
        "name" => "Blocking task",
        "status" => %{"status" => "open"},
        "tags" => [],
        "dependencies" => [
          %{"task_id" => "other", "depends_on" => "task-5", "type" => 1}
        ]
      }

      # Act
      issue = Client.normalize_task(task)

      # Assert
      assert issue.blocked_by == []
    end
  end

  describe "fetch_issues_by_states/2" do
    test "returns normalized issues filtered by given states" do
      # Arrange
      clickup_workflow!()

      request_fun = fn :get, url, _headers, _body ->
        assert url =~ "statuses"

        tasks =
          if url =~ "page=0" do
            [%{"id" => "t-10", "name" => "By state", "status" => %{"status" => "review"}, "tags" => [], "dependencies" => []}]
          else
            []
          end

        {:ok, %{status: 200, body: %{"tasks" => tasks}}}
      end

      # Act
      result = Client.fetch_issues_by_states(["review", "done"], request_fun: request_fun)

      # Assert
      assert {:ok, [%Issue{id: "t-10"}]} = result
    end

    test "returns empty list for empty state_names" do
      # Arrange
      clickup_workflow!()

      # Act
      result = Client.fetch_issues_by_states([])

      # Assert
      assert {:ok, []} = result
    end
  end

  describe "fetch_issue_states_by_ids/2" do
    test "fetches individual tasks by ID" do
      # Arrange
      clickup_workflow!()

      request_fun = fn :get, url, _headers, _body ->
        cond do
          url =~ "/task/t-1/dependency" ->
            {:ok, %{status: 200, body: %{"dependencies" => []}}}

          url =~ "/task/t-1" ->
            {:ok, %{status: 200, body: %{"id" => "t-1", "name" => "One", "status" => %{"status" => "done"}, "tags" => []}}}

          url =~ "/task/t-2/dependency" ->
            {:ok, %{status: 200, body: %{"dependencies" => []}}}

          url =~ "/task/t-2" ->
            {:ok, %{status: 200, body: %{"id" => "t-2", "name" => "Two", "status" => %{"status" => "open"}, "tags" => []}}}
        end
      end

      # Act
      {:ok, issues} = Client.fetch_issue_states_by_ids(["t-1", "t-2"], request_fun: request_fun)

      # Assert
      assert length(issues) == 2
      ids = Enum.map(issues, & &1.id) |> Enum.sort()
      assert ids == ["t-1", "t-2"]
    end

    test "fetches dependencies from the dedicated endpoint when task payload omits them" do
      # Arrange
      clickup_workflow!()

      request_fun = fn :get, url, _headers, _body ->
        cond do
          url =~ "/task/t-1/dependency" ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "dependencies" => [
                   %{"task_id" => "t-1", "depends_on" => "blocker-7", "type" => 0}
                 ]
               }
             }}

          url =~ "/task/t-1" ->
            {:ok,
             %{
               status: 200,
               body: %{"id" => "t-1", "name" => "One", "status" => %{"status" => "done"}, "tags" => []}
             }}
        end
      end

      # Act
      {:ok, [issue]} = Client.fetch_issue_states_by_ids(["t-1"], request_fun: request_fun)

      # Assert
      assert issue.blocked_by == [%{id: "blocker-7", identifier: "blocker-7", state: nil}]
    end

    test "returns empty list for empty IDs" do
      # Arrange
      clickup_workflow!()

      # Act
      result = Client.fetch_issue_states_by_ids([])

      # Assert
      assert {:ok, []} = result
    end

    test "returns error when a single task fetch fails" do
      # Arrange
      clickup_workflow!()

      request_fun = fn :get, _url, _headers, _body ->
        {:ok, %{status: 404, body: %{"err" => "not found"}}}
      end

      # Act
      result = Client.fetch_issue_states_by_ids(["bad-id"], request_fun: request_fun)

      # Assert
      assert {:error, {:clickup_api_status, 404}} = result
    end
  end

  describe "rest/4" do
    test "sends authenticated request and returns body on success" do
      # Arrange
      clickup_workflow!()

      request_fun = fn :post, url, headers, body ->
        assert url =~ "/task/t-1/comment"
        assert Enum.any?(headers, fn {k, _v} -> k == "Authorization" end)
        assert body == %{"comment_text" => "hi"}
        {:ok, %{status: 200, body: %{"id" => "c-1"}}}
      end

      # Act
      result = Client.rest("POST", "/task/t-1/comment", %{"comment_text" => "hi"}, request_fun: request_fun)

      # Assert
      assert {:ok, %{"id" => "c-1"}} = result
    end

    test "returns error on non-2xx status" do
      # Arrange
      clickup_workflow!()

      request_fun = fn :put, _url, _headers, _body ->
        {:ok, %{status: 403, body: %{"err" => "forbidden"}}}
      end

      # Act
      result = Client.rest("PUT", "/task/t-1", %{"status" => "done"}, request_fun: request_fun)

      # Assert
      assert {:error, {:clickup_api_status, 403}} = result
    end

    test "returns error on transport failure" do
      # Arrange
      clickup_workflow!()

      request_fun = fn :get, _url, _headers, _body ->
        {:error, :econnrefused}
      end

      # Act
      result = Client.rest("GET", "/task/t-1", nil, request_fun: request_fun)

      # Assert
      assert {:error, {:clickup_api_request, :econnrefused}} = result
    end

    test "returns missing token error when auth is unavailable" do
      # Arrange
      clickup_workflow!(token: nil)

      # Act
      result = Client.rest("GET", "/task/t-1", nil)

      # Assert
      assert {:error, :missing_tracker_api_token} = result
    end
  end

  describe "fetch_candidate_issues/1" do
    test "returns normalized issues from ClickUp list endpoint" do
      # Arrange
      clickup_workflow!()

      request_fun = fn :get, url, _headers, _body ->
        assert url =~ "/list/list-900/task"

        tasks =
          if url =~ "page=0" do
            [
              %{
                "id" => "t-1",
                "name" => "Task one",
                "status" => %{"status" => "Todo"},
                "tags" => [],
                "dependencies" => []
              }
            ]
          else
            []
          end

        {:ok, %{status: 200, body: %{"tasks" => tasks}}}
      end

      # Act
      result = Client.fetch_candidate_issues(request_fun: request_fun)

      # Assert
      assert {:ok, [%Issue{id: "t-1", title: "Task one"}]} = result
    end

    test "fetches dependencies for candidate issues when list payload omits them" do
      # Arrange
      clickup_workflow!()

      request_fun = fn :get, url, _headers, _body ->
        cond do
          url =~ "/task/t-1/dependency" ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "dependencies" => [
                   %{"task_id" => "t-1", "depends_on" => "blocker-1", "type" => 0}
                 ]
               }
             }}

          url =~ "/list/list-900/task" and url =~ "page=0" ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "tasks" => [
                   %{
                     "id" => "t-1",
                     "name" => "Task one",
                     "status" => %{"status" => "Todo"},
                     "tags" => []
                   }
                 ]
               }
             }}

          url =~ "/list/list-900/task" ->
            {:ok, %{status: 200, body: %{"tasks" => []}}}
        end
      end

      # Act
      {:ok, [issue]} = Client.fetch_candidate_issues(request_fun: request_fun)

      # Assert
      assert issue.blocked_by == [%{id: "blocker-1", identifier: "blocker-1", state: nil}]
    end

    test "paginates through multiple pages" do
      # Arrange
      clickup_workflow!()

      call_count = :counters.new(1, [:atomics])

      request_fun = fn :get, _url, _headers, _body ->
        page = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        tasks =
          if page == 0 do
            [%{"id" => "t-1", "name" => "First", "status" => %{"status" => "Todo"}, "tags" => [], "dependencies" => []}]
          else
            []
          end

        {:ok, %{status: 200, body: %{"tasks" => tasks}}}
      end

      # Act
      {:ok, issues} = Client.fetch_candidate_issues(request_fun: request_fun)

      # Assert
      assert length(issues) == 1
      assert :counters.get(call_count, 1) == 2
    end

    test "returns error on transport failure" do
      # Arrange
      clickup_workflow!()

      request_fun = fn :get, _url, _headers, _body ->
        {:error, :timeout}
      end

      # Act
      result = Client.fetch_candidate_issues(request_fun: request_fun)

      # Assert
      assert {:error, {:clickup_api_request, :timeout}} = result
    end

    test "returns error when dependency fetch fails during candidate polling" do
      # Arrange
      clickup_workflow!()

      request_fun = fn :get, url, _headers, _body ->
        cond do
          url =~ "/task/t-1/dependency" ->
            {:ok, %{status: 429, body: %{"err" => "rate limited"}}}

          url =~ "/list/list-900/task" and url =~ "page=0" ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "tasks" => [
                   %{
                     "id" => "t-1",
                     "name" => "Task one",
                     "status" => %{"status" => "Todo"},
                     "tags" => []
                   }
                 ]
               }
             }}

          url =~ "/list/list-900/task" ->
            {:ok, %{status: 200, body: %{"tasks" => []}}}
        end
      end

      # Act
      result = Client.fetch_candidate_issues(request_fun: request_fun)

      # Assert
      assert {:error, {:clickup_api_status, 429}} = result
    end

    test "returns error on non-200 status" do
      # Arrange
      clickup_workflow!()

      request_fun = fn :get, _url, _headers, _body ->
        {:ok, %{status: 401, body: %{"err" => "Token invalid"}}}
      end

      # Act
      result = Client.fetch_candidate_issues(request_fun: request_fun)

      # Assert
      assert {:error, {:clickup_api_status, 401}} = result
    end
  end
end
