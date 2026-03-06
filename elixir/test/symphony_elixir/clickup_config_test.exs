defmodule SymphonyElixir.ClickUpConfigTest do
  use SymphonyElixir.TestSupport

  describe "ClickUp config validation" do
    test "validates successfully with clickup tracker kind and required fields" do
      # Arrange
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "clickup",
        tracker_api_token: "ck_test_token",
        tracker_list_id: "list-123",
        tracker_project_slug: nil
      )

      # Act
      result = Config.validate!()

      # Assert
      assert result == :ok
    end

    test "rejects clickup kind when api token is missing" do
      # Arrange
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "clickup",
        tracker_api_token: nil,
        tracker_list_id: "list-123",
        tracker_project_slug: nil
      )

      # Act
      result = Config.validate!()

      # Assert
      assert {:error, :missing_tracker_api_token} = result
    end

    test "rejects clickup kind when project id is missing" do
      # Arrange
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "clickup",
        tracker_api_token: "ck_test_token",
        tracker_list_id: nil,
        tracker_project_slug: nil
      )

      # Act
      result = Config.validate!()

      # Assert
      assert {:error, :missing_tracker_project_id} = result
    end

    test "tracker_project_id prefers list_id for clickup" do
      # Arrange
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "clickup",
        tracker_list_id: "list-456",
        tracker_project_slug: "legacy-project-slug"
      )

      # Act
      project_id = Config.tracker_project_id()

      # Assert
      assert project_id == "list-456"
    end

    test "tracker_project_id falls back to project_slug for clickup compatibility" do
      # Arrange
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "clickup",
        tracker_list_id: nil,
        tracker_project_slug: "legacy-project-slug"
      )

      # Act
      project_id = Config.tracker_project_id()

      # Assert
      assert project_id == "legacy-project-slug"
    end

    test "tracker_api_token falls back to CLICKUP_API_KEY env var for clickup kind" do
      # Arrange
      previous = System.get_env("CLICKUP_API_KEY")
      on_exit(fn -> restore_env("CLICKUP_API_KEY", previous) end)

      System.put_env("CLICKUP_API_KEY", "ck_env_token")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "clickup",
        tracker_api_token: nil,
        tracker_list_id: "list-123",
        tracker_project_slug: nil
      )

      # Act
      token = Config.tracker_api_token()

      # Assert
      assert token == "ck_env_token"
    end

    test "tracker_assignee falls back to CLICKUP_ASSIGNEE env var for clickup kind" do
      # Arrange
      previous = System.get_env("CLICKUP_ASSIGNEE")
      on_exit(fn -> restore_env("CLICKUP_ASSIGNEE", previous) end)

      System.put_env("CLICKUP_ASSIGNEE", "clickup-user-1")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "clickup",
        tracker_assignee: nil
      )

      # Act
      assignee = Config.tracker_assignee()

      # Assert
      assert assignee == "clickup-user-1"
    end

    test "tracker_endpoint defaults to ClickUp API for clickup kind" do
      # Arrange
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "clickup",
        tracker_api_token: "ck_test_token",
        tracker_list_id: "list-123",
        tracker_project_slug: nil
      )

      # Act
      endpoint = Config.tracker_endpoint()

      # Assert
      assert endpoint == "https://api.clickup.com/api/v2"
    end

    test "tracker_endpoint uses explicit endpoint when configured for clickup" do
      # Arrange
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "clickup",
        tracker_endpoint: "https://custom.clickup.example.com/api/v2",
        tracker_api_token: "ck_test_token",
        tracker_list_id: "list-123",
        tracker_project_slug: nil
      )

      # Act
      endpoint = Config.tracker_endpoint()

      # Assert
      assert endpoint == "https://custom.clickup.example.com/api/v2"
    end
  end
end
