# Sources, attribution and license

## License for this skill

All text in `cli-ergonomics/SKILL.md` and `cli-ergonomics/references/*.md`,
including this notice, is licensed under the
[Creative Commons Attribution-ShareAlike 4.0 International license](https://creativecommons.org/licenses/by-sa/4.0/).
This applies to this skill's text only, not the surrounding repository.

The rule summaries adapt **Command Line Interface Guidelines** by **Aanand Prasad,
Ben Firshman, Carl Tashian and Eva Parish**, at [clig.dev](https://clig.dev/).
The original is licensed under CC BY-SA 4.0; its
[source and license notice](https://github.com/cli-guidelines/cli-guidelines#license)
are available online. No endorsement is implied.

Changes: condensed and reorganized the guide into area checklists; added an
audit/design workflow, evidence and exact-copy reporting contract, severity rubric,
compatibility/privacy qualifications and review probes. Examples here are newly
written, not copied from the sources. Retain attribution and this license when
sharing or adapting this skill.

## Reading map

| ID | Source | Contribution |
|---|---|---|
| C | [Command Line Interface Guidelines](https://clig.dev/) | Primary basis: human-first design with composability, help, output, errors, inputs, robustness, configuration and distribution |
| H | [Heroku CLI Style Guide](https://devcenter.heroku.com/articles/cli-style-guide) | Consistent command/flag descriptions, action vs data output, filterable records and script compatibility |
| T | [12 Factor CLI Apps, Jeff Dickey](https://medium.com/@jdxcode/12-factor-cli-apps-dd3c227a0e46) | Help and examples, version discoverability, streams, terminal adaptation, table usability, measured startup and platform config paths |

Heroku and 12 Factor are supplementary reading, not relicensed source text.
Their ideas are independently summarized; their wording and examples are not
reproduced. Heroku-specific colon syntax, libraries, color palette and punctuation
are not universal CLI rules.

These references are judgment aids. Explain justified departures in terms of user
tasks and established contracts rather than requiring every tool to add every flag.
