defmodule SymphonyElixir.IssueTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Issue
  alias SymphonyElixir.Linear.Issue, as: LinearIssue

  describe "SymphonyElixir.Issue struct" do
    test "has all expected fields with correct defaults" do
      # Arrange
      issue = %Issue{}

      # Assert
      assert issue.id == nil
      assert issue.identifier == nil
      assert issue.title == nil
      assert issue.description == nil
      assert issue.priority == nil
      assert issue.state == nil
      assert issue.branch_name == nil
      assert issue.url == nil
      assert issue.assignee_id == nil
      assert issue.blocked_by == []
      assert issue.labels == []
      assert issue.assigned_to_worker == true
      assert issue.created_at == nil
      assert issue.updated_at == nil
    end

    test "label_names returns labels list" do
      # Arrange
      issue = %Issue{labels: ["bug", "urgent"]}

      # Act
      result = Issue.label_names(issue)

      # Assert
      assert result == ["bug", "urgent"]
    end

    test "Linear.Issue.label_names delegates to the canonical issue module" do
      # Arrange
      issue = %Issue{labels: ["backend", "bug"]}

      # Act
      result = LinearIssue.label_names(issue)

      # Assert
      assert result == ["backend", "bug"]
    end

    test "can be constructed with all fields" do
      # Arrange
      now = DateTime.utc_now()

      # Act
      issue = %Issue{
        id: "abc-123",
        identifier: "MT-1",
        title: "Fix bug",
        description: "It's broken",
        priority: 1,
        state: "Todo",
        branch_name: "mt-1-fix-bug",
        url: "https://example.com/MT-1",
        assignee_id: "user-1",
        blocked_by: [%{id: "dep-1", identifier: "MT-0", state: "In Progress"}],
        labels: ["bug"],
        assigned_to_worker: false,
        created_at: now,
        updated_at: now
      }

      # Assert
      assert issue.id == "abc-123"
      assert issue.priority == 1
      assert issue.assigned_to_worker == false
      assert issue.blocked_by == [%{id: "dep-1", identifier: "MT-0", state: "In Progress"}]
    end
  end
end
