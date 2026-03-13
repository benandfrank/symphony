defmodule SymphonyElixir.ClickUp.LiveApiTest do
  use SymphonyElixir.TestSupport

  # The problem: all ClickUp unit tests use injected request_fun mocks.
  # Mock responses were hand-crafted against the API reference at a point in
  # time. If ClickUp changes field names, tightens auth, or alters pagination
  # the unit tests keep passing while the integration is silently broken.
  #
  # The solution: these tests call the real ClickUp REST API with real
  # credentials and assert that every Adapter callback produces correct output
  # end-to-end — HTTP, auth, JSON parsing, and normalisation all included.
  #
  # Gating: requires SYMPHONY_RUN_LIVE_CLICKUP=1, CLICKUP_API_KEY,
  # CLICKUP_TEST_LIST_ID, and CLICKUP_TEST_TASK_ID to run.
  # Set up a dedicated ClickUp list + task for CI; do not reuse production data.

  @moduletag :live_clickup
  @moduletag timeout: 60_000

  @live_skip_reason if System.get_env("SYMPHONY_RUN_LIVE_CLICKUP") != "1",
                      do:
                        "set SYMPHONY_RUN_LIVE_CLICKUP=1 and " <>
                          "CLICKUP_API_KEY / CLICKUP_TEST_LIST_ID / CLICKUP_TEST_TASK_ID to run"

  alias SymphonyElixir.ClickUp.Adapter
  alias SymphonyElixir.Issue

  setup do
    # Arrange: configure Symphony for ClickUp using real env credentials.
    # Each test gets a fresh workflow config so there is no shared state.
    list_id = System.get_env("CLICKUP_TEST_LIST_ID") || ""
    task_id = System.get_env("CLICKUP_TEST_TASK_ID") || ""

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "clickup",
      tracker_api_token: "$CLICKUP_API_KEY",
      tracker_list_id: list_id
    )

    {:ok, list_id: list_id, task_id: task_id}
  end

  @tag skip: @live_skip_reason
  test "fetch_candidate_issues/0 returns a list of normalised Issue structs from the real list",
       %{list_id: _list_id} do
    # Arrange — workflow config written in setup

    # Act
    result = Adapter.fetch_candidate_issues()

    # Assert
    assert {:ok, issues} = result
    assert is_list(issues)

    for %Issue{} = issue <- issues do
      assert is_binary(issue.id) and issue.id != "",
             "expected non-empty string id, got: #{inspect(issue.id)}"

      assert is_binary(issue.state),
             "expected binary state for #{issue.id}, got: #{inspect(issue.state)}"

      assert is_list(issue.labels)
      assert is_list(issue.blocked_by)
      assert is_boolean(issue.assigned_to_worker)
    end
  end

  @tag skip: @live_skip_reason
  test "fetch_issue_states_by_ids/1 returns a matching Issue for a known task id",
       %{task_id: task_id} do
    # Arrange — task_id from setup

    # Act
    result = Adapter.fetch_issue_states_by_ids([task_id])

    # Assert
    assert {:ok, [%Issue{} = issue]} = result
    assert issue.id == task_id
    assert is_binary(issue.state) and issue.state != ""
  end

  @tag skip: @live_skip_reason
  test "fetch_issue_states_by_ids/1 fetches multiple ids in parallel within timeout budget",
       %{task_id: task_id} do
    # Arrange — three copies of the same task exercises the parallel path without
    # requiring multiple distinct test tasks to be pre-created
    task_ids = [task_id, task_id, task_id]

    # Act
    {elapsed_us, result} = :timer.tc(fn -> Adapter.fetch_issue_states_by_ids(task_ids) end)

    # Assert
    assert {:ok, issues} = result
    assert length(issues) == 1, "expected deduplication; got #{length(issues)} results"

    assert elapsed_us < 15_000_000,
           "parallel fetch took #{Float.round(elapsed_us / 1_000_000, 2)}s; expected < 15s"
  end

  @tag skip: @live_skip_reason
  test "create_comment/2 returns {:ok, comment_id} with a non-empty binary id",
       %{task_id: task_id} do
    # Arrange
    body = "## Symphony contract test\n\nCreated at #{DateTime.utc_now() |> DateTime.to_iso8601()}"

    # Act
    result = Adapter.create_comment(task_id, body)

    # Assert
    assert {:ok, comment_id} = result

    assert is_binary(comment_id) and comment_id != "",
           "expected non-empty string comment_id; " <>
             "this validates that the `id` field in the ClickUp POST /comment response " <>
             "is present and correctly extracted by the adapter"
  end

  @tag skip: @live_skip_reason
  test "update_comment/2 returns :ok when called with a comment_id from create_comment/2",
       %{task_id: task_id} do
    # Arrange — create a fresh comment to obtain a real comment_id
    {:ok, comment_id} =
      Adapter.create_comment(
        task_id,
        "## Symphony contract test — original\n\nWill be updated."
      )

    # Act
    result =
      Adapter.update_comment(
        comment_id,
        "## Symphony contract test — updated at #{DateTime.utc_now() |> DateTime.to_iso8601()}"
      )

    # Assert
    assert :ok = result
  end
end
