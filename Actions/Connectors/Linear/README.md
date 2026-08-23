# P4.6-b connectors: Linear, Notion, GitHub
- **Linear** (`Linear/`): GraphQL; OAuth scopes `read issues:create comments:create`. create (team key→id), comment (identifier→id), search. Undo hints `issueArchive:`/`commentDelete:`.
- **Notion** (`Notion/`): REST v1 (`Notion-Version 2022-06-28`); OAuth `owner=user`, token exchange needs Basic client secret → `NotionOAuth.exchange`. create page (page/database parent), comment (page or discussion), search.
- **GitHub** (`GitHub/`): REST; auth = fine-grained PAT (`GitHubAuth.storePAT`) or device flow (`GitHubDeviceFlow`, scope `repo`/`public_repo`). create issue, comment on issue/PR (repo+number from fields or github.com URL), search issues.
All go through `ConnectorClient` (bearer, one 401 refresh, every call → Data Panel). Missing target/field → `.fallbackToUI`.
