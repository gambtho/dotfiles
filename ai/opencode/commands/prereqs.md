---
description: Check tool availability for the current project environment
---

# Prerequisite Checker

Check that required tools are available in the current environment. $ARGUMENTS

## Context

- Current directory: !`pwd`
- OS: !`uname -s`

## Instructions

First, try to load the `prereq-checker` skill using the skill tool. If it loads successfully, follow it exactly.

If $ARGUMENTS contains specific tool names (e.g., `/prereqs docker gh cr`), check only those tools.
If no arguments are provided, auto-detect required tools from the project context.
