# Repository Guidance

## Put knowledge where it will remain useful the longest

Choose the home of each piece of information by its purpose:

- **Production code owns How.** Make behavior understandable through names, types,
  control flow, and module boundaries. Do not use comments to narrate an implementation
  that clearer code could express.
- **Tests own What.** Treat tests as executable specifications. Test names, setup, and
  assertions must state the observable contract without depending on implementation
  details.
- **Commit history owns change-specific Why.** Record the problem, motivation, and context
  for a change in the commit message, where future maintainers can inspect the decision
  with its diff. Design rationale that must outlive one change belongs in `docs/adr/`; link
  the commit message to that ADR instead of duplicating it.
- **Implementation comments own Why Not.** Keep an implementation comment only when it
  preserves a constraint that code cannot express: why the obvious approach is unsafe,
  which alternative was rejected, or which external limitation forces the current shape.

Public API documentation comments (`///`) own the observable contract of the API surface.
The Why-Not rule governs implementation comments (`//` and `/* ... */`), not API
documentation. Test and instructional-example comments may state the behavior they specify
or teach, but should not narrate an implementation that clearer code could express.

When refactoring, first improve naming or structure. Remove comments that merely restate
the code, move behavioral requirements into tests, and retain comments only when losing
the rejected-alternative or hidden-constraint context would invite a regression.
