# Shared project rules

Use this rule whenever you add, move, rename, or delete a Markdown instruction for Agent Commander. It also applies when you change a rule's scope or how Claude Code or Codex discovers it.

1. Put the rule's canonical text in a Markdown file under [`.codex/rules/`](.). Update the applicable shared file when an existing rule covers the same topic. Consolidate overlapping instructions so both clients read the same text.
2. Update the [Shared rules section of `AGENTS.md`](../../AGENTS.md#shared-rules) in the same change. For every shared rule file, provide an explicit instruction that says when Codex must read it and add a standalone Claude import using the repository-relative path.

   ```markdown
   Before changing an example workflow, read the [example workflow rules](.codex/rules/EXAMPLE.md).

   @.codex/rules/EXAMPLE.md
   ```

3. Keep [`CLAUDE.md`](../../CLAUDE.md) as the single `@AGENTS.md` import. Claude receives shared rules through the imports in `AGENTS.md`. Keep project rule text in the shared files, including rules that name responsibilities for only one client.
4. Before calling the change ready, verify that every shared rule has both entries in `AGENTS.md`, that both entries resolve to the same file, and that references to renamed or deleted files have been updated. Fix missing, duplicate, and stale rule references in the same change.
