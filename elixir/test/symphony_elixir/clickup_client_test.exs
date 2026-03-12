defmodule SymphonyElixir.ClickUp.ClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ClickUp.Client
  alias SymphonyElixir.Issue

  defp clickup_workflow!(opts \\ []) do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "clickup",
      tracker_api_token: Keyword.get(opts, :token, "ck_test"),
      tracker_list_id: Keyword.get(opts, :list_id, "list-900"),
      tracker_project_slug: nil,
      tracker_assignee: Keyword.get(opts, :assignee, nil)
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

    test "normalizes integer priorities, string assignee ids, and invalid timestamps defensively" do
      # Arrange
      task = %{
        "id" => "task-3b",
        "name" => "Edge task",
        "status" => %{"status" => "todo"},
        "priority" => %{"id" => 4},
        "assignees" => [%{"id" => "user-7"}],
        "tags" => [%{"name" => nil}],
        "date_created" => "not-a-timestamp",
        "date_updated" => :bad,
        "dependencies" => []
      }

      # Act
      issue = Client.normalize_task(task)

      # Assert
      assert issue.priority == 4
      assert issue.assignee_id == "user-7"
      assert issue.labels == []
      assert issue.created_at == nil
      assert issue.updated_at == nil
    end

    test "returns nil priority for out-of-range string priority id" do
      # Arrange
      task = %{
        "id" => "task-p",
        "name" => "Bad priority",
        "status" => %{"status" => "open"},
        "priority" => %{"id" => "99"},
        "tags" => [],
        "dependencies" => []
      }

      # Act
      issue = Client.normalize_task(task)

      # Assert
      assert issue.priority == nil
    end

    test "returns empty labels when tags key is absent" do
      # Arrange
      task = %{
        "id" => "task-no-tags",
        "name" => "No tags key",
        "status" => %{"status" => "open"},
        "dependencies" => []
      }

      # Act
      issue = Client.normalize_task(task)

      # Assert
      assert issue.labels == []
    end

    test "returns empty blockers and deps when task has no id key" do
      # Arrange
      task = %{
        "name" => "No id task",
        "status" => %{"status" => "open"},
        "tags" => []
      }

      # Act
      issue = Client.normalize_task(task)

      # Assert
      assert issue.blocked_by == []
      assert issue.id == nil
    end

    test "parses integer timestamps" do
      # Arrange
      task = %{
        "id" => "task-int-ts",
        "name" => "Integer timestamps",
        "status" => %{"status" => "open"},
        "tags" => [],
        "dependencies" => [],
        "date_created" => 1_677_000_000_000,
        "date_updated" => 1_677_100_000_000
      }

      # Act
      issue = Client.normalize_task(task)

      # Assert
      assert %DateTime{} = issue.created_at
      assert %DateTime{} = issue.updated_at
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
    test "returns missing token error when auth is unavailable" do
      # Arrange
      clickup_workflow!(token: nil)

      # Act
      result = Client.fetch_issues_by_states(["review"])

      # Assert
      assert {:error, :missing_tracker_api_token} = result
    end

    test "returns missing project id error when list_id is absent" do
      # Arrange
      clickup_workflow!(list_id: nil)

      # Act
      result = Client.fetch_issues_by_states(["review"])

      # Assert
      assert {:error, :missing_tracker_project_id} = result
    end

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
    test "marks reconciled issues as assigned_to_worker when assignee matches workflow config" do
      # Arrange
      clickup_workflow!(assignee: "12345")

      request_fun = fn :get, url, _headers, _body ->
        cond do
          url =~ "/task/t-1/dependency" ->
            {:ok, %{status: 200, body: %{"dependencies" => []}}}

          url =~ "/task/t-1" ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "id" => "t-1",
                 "name" => "One",
                 "status" => %{"status" => "done"},
                 "assignees" => [%{"id" => 12_345}],
                 "tags" => []
               }
             }}
        end
      end

      # Act
      {:ok, [issue]} = Client.fetch_issue_states_by_ids(["t-1"], request_fun: request_fun)

      # Assert
      assert issue.assigned_to_worker == true
    end

    test "marks reconciled issues as not assigned_to_worker when assignee does not match" do
      # Arrange
      clickup_workflow!(assignee: "12345")

      request_fun = fn :get, url, _headers, _body ->
        cond do
          url =~ "/task/t-1/dependency" ->
            {:ok, %{status: 200, body: %{"dependencies" => []}}}

          url =~ "/task/t-1" ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "id" => "t-1",
                 "name" => "One",
                 "status" => %{"status" => "done"},
                 "assignees" => [%{"id" => 99_999}],
                 "tags" => []
               }
             }}
        end
      end

      # Act
      {:ok, [issue]} = Client.fetch_issue_states_by_ids(["t-1"], request_fun: request_fun)

      # Assert
      assert issue.assigned_to_worker == false
    end

    test "returns missing token error when auth is unavailable" do
      # Arrange
      clickup_workflow!(token: nil)

      # Act
      result = Client.fetch_issue_states_by_ids(["t-1"])

      # Assert
      assert {:error, :missing_tracker_api_token} = result
    end

    test "returns error when a fetched task payload is not a map" do
      # Arrange
      clickup_workflow!()

      request_fun = fn :get, url, _headers, _body ->
        if url =~ "/task/t-1" do
          {:ok, %{status: 200, body: ["bad"]}}
        else
          flunk("unexpected dependency request for malformed task payload")
        end
      end

      # Act
      result = Client.fetch_issue_states_by_ids(["t-1"], request_fun: request_fun)

      # Assert
      assert {:error, {:clickup_api_status, 200}} = result
    end

    test "returns dependency transport errors during reconciliation" do
      # Arrange
      clickup_workflow!()

      request_fun = fn :get, url, _headers, _body ->
        cond do
          url =~ "/task/t-1/dependency" -> {:error, :timeout}
          url =~ "/task/t-1" -> {:ok, %{status: 200, body: %{"id" => "t-1", "name" => "One", "status" => %{"status" => "done"}, "tags" => []}}}
        end
      end

      # Act
      result = Client.fetch_issue_states_by_ids(["t-1"], request_fun: request_fun)

      # Assert
      assert {:error, {:clickup_api_request, :timeout}} = result
    end

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

    test "returns transport error when task fetch encounters a connection failure" do
      # Arrange
      clickup_workflow!()

      request_fun = fn :get, _url, _headers, _body ->
        {:error, :econnrefused}
      end

      # Act
      result = Client.fetch_issue_states_by_ids(["t-1"], request_fun: request_fun)

      # Assert
      assert {:error, {:clickup_api_request, :econnrefused}} = result
    end

    test "returns exit error when async task fetch times out" do
      # Arrange
      clickup_workflow!()

      request_fun = fn :get, _url, _headers, _body ->
        Process.sleep(:infinity)
      end

      # Act
      result =
        Client.fetch_issue_states_by_ids(["t-1"],
          request_fun: request_fun,
          async_timeout: 1
        )

      # Assert
      assert {:error, {:clickup_task_fetch_exit, _reason}} = result
    end

    test "retries 429 from single task fetch and succeeds" do
      # Arrange
      clickup_workflow!()

      responses = Agent.start_link(fn -> [:rate_limited, :ok_task, :ok_dep] end) |> then(fn {:ok, pid} -> pid end)

      request_fun = fn :get, url, _headers, _body ->
        cond do
          url =~ "/task/t-1/dependency" ->
            {:ok, %{status: 200, body: %{"dependencies" => []}}}

          url =~ "/task/t-1" ->
            Agent.get_and_update(responses, fn [h | t] -> {h, t} end)
            |> case do
              :rate_limited -> {:ok, %{status: 429, body: %{}}}
              :ok_task -> {:ok, %{status: 200, body: %{"id" => "t-1", "name" => "Task", "status" => %{"status" => "done"}, "tags" => []}}}
            end
        end
      end

      recorded_delays = :ets.new(:ids_task_retry, [:bag, :public])

      sleep_fun = fn ms ->
        :ets.insert(recorded_delays, {:delay, ms})
        :ok
      end

      # Act
      result = Client.fetch_issue_states_by_ids(["t-1"], request_fun: request_fun, sleep_fun: sleep_fun)

      # Assert
      assert {:ok, [%Issue{id: "t-1"}]} = result
      assert [{:delay, _}] = :ets.lookup(recorded_delays, :delay)
    end

    test "retries 429 from dependency endpoint during reconciliation and succeeds" do
      # Arrange
      clickup_workflow!()

      dep_responses = Agent.start_link(fn -> [:rate_limited, :ok] end) |> then(fn {:ok, pid} -> pid end)

      request_fun = fn :get, url, _headers, _body ->
        cond do
          url =~ "/task/t-1/dependency" ->
            Agent.get_and_update(dep_responses, fn [h | t] -> {h, t} end)
            |> case do
              :rate_limited -> {:ok, %{status: 429, body: %{}}}
              :ok -> {:ok, %{status: 200, body: %{"dependencies" => []}}}
            end

          url =~ "/task/t-1" ->
            {:ok, %{status: 200, body: %{"id" => "t-1", "name" => "Task", "status" => %{"status" => "done"}, "tags" => []}}}
        end
      end

      recorded_delays = :ets.new(:ids_dep_retry, [:bag, :public])

      sleep_fun = fn ms ->
        :ets.insert(recorded_delays, {:delay, ms})
        :ok
      end

      # Act
      result = Client.fetch_issue_states_by_ids(["t-1"], request_fun: request_fun, sleep_fun: sleep_fun)

      # Assert
      assert {:ok, [%Issue{id: "t-1"}]} = result
      assert [{:delay, _}] = :ets.lookup(recorded_delays, :delay)
    end
  end

  describe "rest/4" do
    test "accepts atom methods for direct REST calls" do
      # Arrange
      clickup_workflow!()

      request_fun = fn :get, url, headers, body ->
        assert url =~ "/task/t-1"
        assert Enum.any?(headers, fn {k, _v} -> k == "Authorization" end)
        assert body == nil
        {:ok, %{status: 200, body: %{"id" => "t-1"}}}
      end

      # Act
      result = Client.rest(:get, "/task/t-1", nil, request_fun: request_fun)

      # Assert
      assert {:ok, %{"id" => "t-1"}} = result
    end

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

    test "retries 429 response and succeeds on the next attempt" do
      # Arrange
      clickup_workflow!()

      responses = Agent.start_link(fn -> [:rate_limited, :ok] end) |> then(fn {:ok, pid} -> pid end)

      request_fun = fn :get, _url, _headers, _body ->
        Agent.get_and_update(responses, fn [h | t] -> {h, t} end)
        |> case do
          :rate_limited -> {:ok, %{status: 429, body: %{}}}
          :ok -> {:ok, %{status: 200, body: %{"id" => "t-1"}}}
        end
      end

      recorded_delays = :ets.new(:rest_retry_delays, [:bag, :public])

      sleep_fun = fn ms ->
        :ets.insert(recorded_delays, {:delay, ms})
        :ok
      end

      # Act
      result = Client.rest(:get, "/task/t-1", nil, request_fun: request_fun, sleep_fun: sleep_fun)

      # Assert
      assert {:ok, %{"id" => "t-1"}} = result
      assert [{:delay, _}] = :ets.lookup(recorded_delays, :delay)
    end

    test "does not retry non-429 responses in rest/4" do
      # Arrange
      clickup_workflow!()

      calls = :counters.new(1, [:atomics])

      request_fun = fn :put, _url, _headers, _body ->
        :counters.add(calls, 1, 1)
        {:ok, %{status: 400, body: %{"err" => "bad request"}}}
      end

      # Act
      result = Client.rest("PUT", "/task/t-1", %{}, request_fun: request_fun, sleep_fun: fn _ms -> :ok end)

      # Assert
      assert {:error, {:clickup_api_status, 400}} = result
      assert :counters.get(calls, 1) == 1
    end
  end

  describe "fetch_candidate_issues/1" do
    test "includes limit=100 in list endpoint URL" do
      # Arrange
      clickup_workflow!()

      request_fun = fn :get, url, _headers, _body ->
        assert url =~ "limit=100"
        {:ok, %{status: 200, body: %{"tasks" => []}}}
      end

      # Act
      result = Client.fetch_candidate_issues(request_fun: request_fun)

      # Assert
      assert {:ok, []} = result
    end

    test "marks issues as assigned_to_worker when assignee matches workflow config" do
      # Arrange
      clickup_workflow!(assignee: "12345")

      request_fun = fn :get, url, _headers, _body ->
        tasks =
          if url =~ "page=0" do
            [
              %{
                "id" => "t-1",
                "name" => "Task one",
                "status" => %{"status" => "Todo"},
                "assignees" => [%{"id" => 12_345}],
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
      {:ok, [issue]} = Client.fetch_candidate_issues(request_fun: request_fun)

      # Assert
      assert issue.assigned_to_worker == true
    end

    test "marks issues as not assigned_to_worker when assignee does not match workflow config" do
      # Arrange
      clickup_workflow!(assignee: "12345")

      request_fun = fn :get, url, _headers, _body ->
        tasks =
          if url =~ "page=0" do
            [
              %{
                "id" => "t-1",
                "name" => "Task one",
                "status" => %{"status" => "Todo"},
                "assignees" => [%{"id" => 99_999}],
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
      {:ok, [issue]} = Client.fetch_candidate_issues(request_fun: request_fun)

      # Assert
      assert issue.assigned_to_worker == false
    end

    test "marks unassigned issues as not assigned_to_worker when assignee filter is configured" do
      # Arrange
      clickup_workflow!(assignee: "12345")

      request_fun = fn :get, url, _headers, _body ->
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
      {:ok, [issue]} = Client.fetch_candidate_issues(request_fun: request_fun)

      # Assert
      assert issue.assigned_to_worker == false
    end

    test "matches any assignee in a multi-assignee task" do
      # Arrange
      clickup_workflow!(assignee: "12345")

      request_fun = fn :get, url, _headers, _body ->
        tasks =
          if url =~ "page=0" do
            [
              %{
                "id" => "t-1",
                "name" => "Task one",
                "status" => %{"status" => "Todo"},
                "assignees" => [%{"id" => 99_999}, %{"id" => 12_345}],
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
      {:ok, [issue]} = Client.fetch_candidate_issues(request_fun: request_fun)

      # Assert
      assert issue.assigned_to_worker == true
    end

    test "matches string assignee ids against configured assignee" do
      # Arrange
      clickup_workflow!(assignee: "user-7")

      request_fun = fn :get, url, _headers, _body ->
        tasks =
          if url =~ "page=0" do
            [
              %{
                "id" => "t-1",
                "name" => "Task one",
                "status" => %{"status" => "Todo"},
                "assignees" => [%{"id" => "user-7"}],
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
      {:ok, [issue]} = Client.fetch_candidate_issues(request_fun: request_fun)

      # Assert
      assert issue.assigned_to_worker == true
    end

    test "treats malformed assignee entries as non-matching" do
      # Arrange
      clickup_workflow!(assignee: "12345")

      request_fun = fn :get, url, _headers, _body ->
        tasks =
          if url =~ "page=0" do
            [
              %{
                "id" => "t-1",
                "name" => "Task one",
                "status" => %{"status" => "Todo"},
                "assignees" => [%{"username" => "jdoe"}],
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
      {:ok, [issue]} = Client.fetch_candidate_issues(request_fun: request_fun)

      # Assert
      assert issue.assigned_to_worker == false
    end

    test "uses CLICKUP_ASSIGNEE env fallback when workflow assignee is unset" do
      # Arrange
      original_assignee = System.get_env("CLICKUP_ASSIGNEE")
      System.put_env("CLICKUP_ASSIGNEE", "12345")
      clickup_workflow!()

      on_exit(fn -> restore_env("CLICKUP_ASSIGNEE", original_assignee) end)

      request_fun = fn :get, url, _headers, _body ->
        tasks =
          if url =~ "page=0" do
            [
              %{
                "id" => "t-1",
                "name" => "Task one",
                "status" => %{"status" => "Todo"},
                "assignees" => [%{"id" => 12_345}],
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
      {:ok, [issue]} = Client.fetch_candidate_issues(request_fun: request_fun)

      # Assert
      assert issue.assigned_to_worker == true
    end

    test "returns missing project id error when list_id is absent" do
      # Arrange
      clickup_workflow!(list_id: nil)

      # Act
      result = Client.fetch_candidate_issues()

      # Assert
      assert {:error, :missing_tracker_project_id} = result
    end

    test "returns accumulated issues when task list payload is malformed on a later page" do
      # Arrange
      clickup_workflow!()

      request_fun = fn :get, url, _headers, _body ->
        if url =~ "page=0" do
          {:ok,
           %{
             status: 200,
             body: %{
               "tasks" => [
                 %{"id" => "t-1", "name" => "Task one", "status" => %{"status" => "Todo"}, "tags" => [], "dependencies" => []}
               ]
             }
           }}
        else
          {:ok, %{status: 200, body: %{"unexpected" => []}}}
        end
      end

      # Act
      result = Client.fetch_candidate_issues(request_fun: request_fun)

      # Assert
      assert {:ok, [%Issue{id: "t-1"}]} = result
    end

    test "returns empty blockers when dependency endpoint returns 200 without dependencies array" do
      # Arrange
      clickup_workflow!()

      request_fun = fn :get, url, _headers, _body ->
        cond do
          url =~ "/task/t-1/dependency" ->
            {:ok, %{status: 200, body: %{"something_else" => []}}}

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
      assert issue.blocked_by == []
    end

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

    test "handles tasks with no id or dependencies key via catch-all" do
      # Arrange
      clickup_workflow!()

      request_fun = fn :get, url, _headers, _body ->
        if url =~ "page=0" do
          {:ok,
           %{
             status: 200,
             body: %{
               "tasks" => [
                 %{
                   "name" => "No id task",
                   "status" => %{"status" => "Todo"},
                   "tags" => []
                 }
               ]
             }
           }}
        else
          {:ok, %{status: 200, body: %{"tasks" => []}}}
        end
      end

      # Act
      {:ok, [issue]} = Client.fetch_candidate_issues(request_fun: request_fun)

      # Assert
      assert issue.id == nil
      assert issue.blocked_by == []
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

    test "returns error when dependency fetch exhausts all retries" do
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

      # Act — inject no-op sleep_fun to keep test fast across retries
      result = Client.fetch_candidate_issues(request_fun: request_fun, sleep_fun: fn _ms -> :ok end)

      # Assert
      assert {:error, {:clickup_api_status, 429}} = result
    end

    test "retries list endpoint 429 and succeeds on the next attempt" do
      # Arrange
      clickup_workflow!()

      responses = Agent.start_link(fn -> [:rate_limited, :ok, :done] end) |> then(fn {:ok, pid} -> pid end)

      request_fun = fn :get, url, _headers, _body ->
        if url =~ "/list/list-900/task" do
          Agent.get_and_update(responses, fn [h | t] -> {h, t} end)
          |> case do
            :rate_limited ->
              {:ok, %{status: 429, body: %{}}}

            :ok ->
              task = %{"id" => "t-1", "name" => "Task", "status" => %{"status" => "Todo"}, "tags" => [], "dependencies" => []}
              {:ok, %{status: 200, body: %{"tasks" => [task]}}}

            :done ->
              {:ok, %{status: 200, body: %{"tasks" => []}}}
          end
        else
          {:ok, %{status: 200, body: %{"dependencies" => []}}}
        end
      end

      recorded_delays = :ets.new(:clickup_list_delays, [:bag, :public])

      sleep_fun = fn ms ->
        :ets.insert(recorded_delays, {:delay, ms})
        :ok
      end

      # Act
      result = Client.fetch_candidate_issues(request_fun: request_fun, sleep_fun: sleep_fun)

      # Assert
      assert {:ok, [%Issue{id: "t-1"}]} = result
      assert [{:delay, _}] = :ets.lookup(recorded_delays, :delay)
    end

    test "honors Retry-After header from list endpoint 429" do
      # Arrange
      clickup_workflow!()

      responses = Agent.start_link(fn -> [:rate_limited, :ok, :done] end) |> then(fn {:ok, pid} -> pid end)

      request_fun = fn :get, url, _headers, _body ->
        if url =~ "/list/list-900/task" do
          Agent.get_and_update(responses, fn [h | t] -> {h, t} end)
          |> case do
            :rate_limited ->
              {:ok, %{status: 429, body: %{}, headers: %{"retry-after" => ["4"]}}}

            :ok ->
              task = %{"id" => "t-2", "name" => "Task", "status" => %{"status" => "Todo"}, "tags" => [], "dependencies" => []}
              {:ok, %{status: 200, body: %{"tasks" => [task]}}}

            :done ->
              {:ok, %{status: 200, body: %{"tasks" => []}}}
          end
        else
          {:ok, %{status: 200, body: %{"dependencies" => []}}}
        end
      end

      recorded_delays = :ets.new(:clickup_list_retry_after, [:bag, :public])

      sleep_fun = fn ms ->
        :ets.insert(recorded_delays, {:delay, ms})
        :ok
      end

      # Act
      {:ok, _} = Client.fetch_candidate_issues(request_fun: request_fun, sleep_fun: sleep_fun)

      # Assert — delay comes from Retry-After: 4 → 4_000 ms
      assert [{:delay, 4_000}] = :ets.lookup(recorded_delays, :delay)
    end

    test "does not retry non-429 list status errors" do
      # Arrange
      clickup_workflow!()

      calls = :counters.new(1, [:atomics])

      request_fun = fn :get, _url, _headers, _body ->
        :counters.add(calls, 1, 1)
        {:ok, %{status: 503, body: %{}}}
      end

      # Act
      result = Client.fetch_candidate_issues(request_fun: request_fun, sleep_fun: fn _ms -> :ok end)

      # Assert — only one attempt, no retry
      assert {:error, {:clickup_api_status, 503}} = result
      assert :counters.get(calls, 1) == 1
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

    test "returns exit error when async dependency fetch times out" do
      # Arrange
      clickup_workflow!()

      request_fun = fn :get, url, _headers, _body ->
        cond do
          url =~ "/task/t-1/dependency" ->
            Process.sleep(:infinity)

          url =~ "/list/list-900/task" and url =~ "page=0" ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "tasks" => [
                   %{
                     "id" => "t-1",
                     "name" => "Slow dep task",
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
      result =
        Client.fetch_candidate_issues(
          request_fun: request_fun,
          async_timeout: 1
        )

      # Assert
      assert {:error, {:clickup_dependency_fetch_exit, _reason}} = result
    end
  end
end
