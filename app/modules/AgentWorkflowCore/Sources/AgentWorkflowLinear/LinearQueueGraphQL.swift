enum LinearQueueGraphQL {
  static let maximumPages = 40
  static let account = "query QueueAccount { organization { id } viewer { id } }"

  static let teams = """
    query QueueProjectTeams($projectID: String!, $after: String) {
      project(id: $projectID) {
        id
        teams(first: 50, after: $after) {
          nodes { id name key }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
    """

  static let states = """
    query QueueTeamStates($teamID: String!, $after: String) {
      team(id: $teamID) {
        id
        states(first: 50, after: $after) {
          nodes { id name type position color }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
    """

  private static let issueFields = """
    id identifier title updatedAt archivedAt priority sortOrder
    project { id }
    team { id }
    assignee { id }
    state { id name type position color }
    """

  private static let relationFields = """
    nodes {
      id type relatedIssue { id }
      issue { id archivedAt state { type } }
    }
    pageInfo { hasNextPage endCursor }
    """

  static func issues(includeDependencies: Bool) -> String {
    let relations = includeDependencies ? "inverseRelations(first: 10) { \(relationFields) }" : ""
    return """
      query QueueProjectIssues($projectID: String!, $after: String) {
        project(id: $projectID) {
          id
          issues(first: 50, after: $after) {
            nodes { \(issueFields) \(relations) }
            pageInfo { hasNextPage endCursor }
          }
        }
      }
      """
  }

  static let issue = """
    query QueueIssue($issueID: ID!) {
      issues(filter: { id: { eq: $issueID } }, first: 2, includeArchived: true) {
        nodes { \(issueFields) }
        pageInfo { hasNextPage endCursor }
      }
    }
    """

  static let dependencies = """
    query QueueDependencies($issueID: String!, $after: String) {
      issue(id: $issueID) {
        id
        inverseRelations(first: 50, after: $after) { \(relationFields) }
      }
    }
    """
}
