defmodule SymphonyElixir.ClickUp.AdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ClickUp.Adapter

  defp clickup_workflow!(overrides \\ []) do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge(
        [
          tracker_kind: "clickup",
          tracker_api_token: "ck_test",
          tracker_list_id: "list-900",
          tracker_project_slug: nil
        ],
        overrides
      )
    )
  end

  describe "Tracker dispatch with clickup kind" do
    test "adapter/0 returns ClickUp.Adapter for clickup kind" do
      # Arrange
      clickup_workflow!()

      # Act
      adapter = Tracker.adapter()

      # Assert
      assert adapter == Adapter
    end

    test "adapter/0 raises on unsupported tracker kind" do
      # Arrange
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "jira")

      # Act & Assert
      assert_raise ArgumentError, ~r/unsupported tracker kind/, fn ->
        Tracker.adapter()
      end
    end

    test "adapter exports all Tracker behaviour callbacks" do
      # Arrange & Act
      Code.ensure_loaded!(Adapter)

      # Assert
      assert function_exported?(Adapter, :fetch_candidate_issues, 0)
      assert function_exported?(Adapter, :fetch_issues_by_states, 1)
      assert function_exported?(Adapter, :fetch_issue_states_by_ids, 1)
      assert function_exported?(Adapter, :create_comment, 2)
      assert function_exported?(Adapter, :update_issue_state, 2)
    end

    test "fetch_issues_by_states delegates and returns empty for empty states" do
      # Arrange
      clickup_workflow!()

      # Act
      result = Adapter.fetch_issues_by_states([])

      # Assert
      assert {:ok, []} = result
    end

    test "fetch_issue_states_by_ids delegates and returns empty for empty ids" do
      # Arrange
      clickup_workflow!()

      # Act
      result = Adapter.fetch_issue_states_by_ids([])

      # Assert
      assert {:ok, []} = result
    end

    test "fetch_candidate_issues returns missing token error when token is absent" do
      # Arrange
      clickup_workflow!(tracker_api_token: nil)

      # Act
      result = Adapter.fetch_candidate_issues()

      # Assert
      assert {:error, :missing_tracker_api_token} = result
    end

    test "fetch_candidate_issues delegates through injected function" do
      # Arrange
      clickup_workflow!()

      # Act
      result =
        Adapter.fetch_candidate_issues(fetch_candidate_issues_fun: fn -> {:ok, [:from_injected_fun]} end)

      # Assert
      assert {:ok, [:from_injected_fun]} = result
    end

    test "fetch_issues_by_states delegates through injected function" do
      # Arrange
      clickup_workflow!()

      # Act
      result =
        Adapter.fetch_issues_by_states(["Done"],
          fetch_issues_by_states_fun: fn states -> {:ok, states} end
        )

      # Assert
      assert {:ok, ["Done"]} = result
    end

    test "fetch_issue_states_by_ids delegates through injected function" do
      # Arrange
      clickup_workflow!()

      # Act
      result =
        Adapter.fetch_issue_states_by_ids(["task-42"],
          fetch_issue_states_by_ids_fun: fn ids -> {:ok, ids} end
        )

      # Assert
      assert {:ok, ["task-42"]} = result
    end

    test "create_comment returns ok on successful REST write" do
      # Arrange
      clickup_workflow!()

      # Act
      result =
        Adapter.create_comment("task-42", "hello",
          rest_fun: fn method, path, body ->
            assert {method, path, body} == {"POST", "/task/task-42/comment", %{"comment_text" => "hello"}}
            {:ok, %{"id" => "comment-1"}}
          end
        )

      # Assert
      assert :ok = result
    end

    test "create_comment returns missing token error when token is absent" do
      # Arrange
      clickup_workflow!(tracker_api_token: nil)

      # Act
      result = Adapter.create_comment("task-42", "hello")

      # Assert
      assert {:error, :missing_tracker_api_token} = result
    end

    test "create_comment returns passthrough errors from REST writes" do
      # Arrange
      clickup_workflow!()

      # Act
      result =
        Adapter.create_comment("task-42", "hello", rest_fun: fn _method, _path, _body -> {:error, {:clickup_api_status, 429}} end)

      # Assert
      assert {:error, {:clickup_api_status, 429}} = result
    end

    test "update_issue_state returns ok on successful REST write" do
      # Arrange
      clickup_workflow!()

      # Act
      result =
        Adapter.update_issue_state("task-42", "Done",
          rest_fun: fn method, path, body ->
            assert {method, path, body} == {"PUT", "/task/task-42", %{"status" => "Done"}}
            {:ok, %{"id" => "task-42"}}
          end
        )

      # Assert
      assert :ok = result
    end

    test "update_issue_state returns missing token error when token is absent" do
      # Arrange
      clickup_workflow!(tracker_api_token: nil)

      # Act
      result = Adapter.update_issue_state("task-42", "Done")

      # Assert
      assert {:error, :missing_tracker_api_token} = result
    end

    test "update_issue_state returns passthrough errors from REST writes" do
      # Arrange
      clickup_workflow!()

      # Act
      result =
        Adapter.update_issue_state("task-42", "Done",
          rest_fun: fn _method, _path, _body ->
            {:error, {:clickup_api_request, :timeout}}
          end
        )

      # Assert
      assert {:error, {:clickup_api_request, :timeout}} = result
    end
  end
end
