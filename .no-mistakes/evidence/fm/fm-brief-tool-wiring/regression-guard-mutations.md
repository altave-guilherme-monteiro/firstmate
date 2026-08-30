# Regression guards: mutation-tested

Each mutation was applied to a scratch copy of HEAD in /tmp (the worktree was never modified),
then the unmodified tests/fm-brief.test.sh was run against it.

## Mutation A - reintroduce PR wording on a wrapped continuation line
(the exact escape review round 3 described: a second prose line containing neither
'semgrep' nor 'context7', which the old per-line grep extraction would have dropped)

```diff
-Fix those or explicitly justify them wherever this task's result is written up;
+Fix those.
+Explicitly justify anything you keep in the PR body;
```

```
not ok - local-only brief's Setup section must not name a PR that mode never opens, on any line
```

## Mutation B - fork the shared guidance for direct-PR mode only

```diff
+    SEMGREP_NOTE_SHIP="${SEMGREP_NOTE_SHIP} Record the justification in the PR body."
     RULE1='1. Never push to the default branch (push only your `fm/'"$ID"'` branch). Never merge a PR.'
```

```
not ok - tool guidance must render identically in local-only and direct-PR briefs, not fork per delivery mode
```

## Unmutated HEAD

```
ok - fm-brief: scout and secondmate code paths still scaffold well-formed briefs
ok - fm-brief: ship and scout briefs carry semgrep and context7 tool guidance
ok - fm-brief: graphify declaration appears only under the config/codebase-graph opt-in
```
