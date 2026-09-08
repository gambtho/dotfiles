import { pathToFileURL } from "node:url";

type ExpectedDecision = "allow" | "ask" | "deny";

type PipelineCase = {
  label: string;
  command: string;
  expected: ExpectedDecision;
  agentName?: "rush" | "smart" | "deep" | "review";
  surface?: string;
  pattern?: string;
};

export type PipelineCheckOptions = {
  packageRoot: string;
  agentDir: string;
  repoRoot: string;
};

type PipelineOutcome = { action: "allow" } | { action: "block"; reason: string };

type PermissionManagerLike = {
  configureForCwd(cwd: string): void;
};

type SessionRulesLike = {
  getRuleset(): unknown[];
  recordSessionApproval(approval: unknown): void;
};

type PermissionResolverLike = object;
type PathNormalizerLike = object;
type GateRunnerLike = object;

type ToolCallContextLike = {
  toolName: string;
  agentName: string | null;
  input: unknown;
  toolCallId: string;
  cwd: string;
};

type ToolCallGateInputsLike = {
  getActiveSkillEntries(): unknown[];
  getInfrastructureReadDirs(): string[];
  getToolPreviewLimits(): unknown;
  getPathNormalizer(): PathNormalizerLike;
  getShellToolAliases(): undefined;
};

type ToolCallGatePipelineLike = {
  evaluate(context: ToolCallContextLike, runner: GateRunnerLike): Promise<PipelineOutcome>;
};

type PromptDecision = {
  approved: false;
  state: "denied";
  decidedBy: { kind: "user"; via: "dialog" };
};

type PrompterLike = {
  escalate(details: Record<string, unknown>): Promise<PromptDecision>;
};

type ReporterLike = {
  writeReviewLog(event: string, details: Record<string, unknown>): void;
  emitDecision(event: Record<string, unknown>): void;
};

const BASELINE_PIPELINE_CASES: PipelineCase[] = [
  { label: "ordinary reader", command: "pwd", expected: "allow" },
  {
    label: "recursive deletion asks",
    command: "rm -rf /tmp/pi-permission-example",
    expected: "ask",
    surface: "bash",
    pattern: "*rm * /*/* *",
  },
  {
    label: "privilege escalation denies",
    command: "sudo true",
    expected: "deny",
    surface: "bash",
    pattern: "*sudo *",
  },
];

const url = (root: string, path: string) =>
  pathToFileURL(`${root}/src/${path}`).href;

function fail(testCase: PipelineCase, message: string): never {
  throw new Error(`pipeline ${testCase.label}: ${message}`);
}

function asRecord(value: unknown): Record<string, unknown> | undefined {
  return typeof value === "object" && value !== null
    ? (value as Record<string, unknown>)
    : undefined;
}

function expectAction(
  testCase: PipelineCase,
  outcome: PipelineOutcome,
  expected: PipelineOutcome["action"],
): void {
  if (outcome.action !== expected) {
    fail(testCase, `expected terminal ${expected}, received ${outcome.action}`);
  }
}

function expectPromptCount(
  testCase: PipelineCase,
  prompts: Array<Record<string, unknown>>,
  expected: number,
): void {
  if (prompts.length !== expected) {
    fail(testCase, `expected ${expected} prompts, received ${prompts.length}`);
  }
}

function expectEvidence(
  testCase: PipelineCase,
  evidence: Record<string, unknown> | undefined,
): void {
  if (!evidence) {
    fail(testCase, "missing policy evidence");
  }
  if (testCase.surface !== undefined && evidence.surface !== testCase.surface) {
    fail(
      testCase,
      `expected surface ${JSON.stringify(testCase.surface)}, received ${JSON.stringify(evidence.surface)}`,
    );
  }
  if (testCase.pattern !== undefined && evidence.matchedPattern !== testCase.pattern) {
    fail(
      testCase,
      `expected pattern ${JSON.stringify(testCase.pattern)}, received ${JSON.stringify(evidence.matchedPattern)}`,
    );
  }
}

export async function runPermissionPipelineChecks({
  packageRoot,
  agentDir,
  repoRoot,
}: PipelineCheckOptions): Promise<void> {
  const [
    { PermissionManager },
    { PermissionResolver },
    { SessionRules },
    { ToolCallGatePipeline },
    { GateRunner },
    { PathNormalizer },
    { posixPathFlavor },
    { resolveToolPreviewLimits },
  ] = (await Promise.all([
    import(url(packageRoot, "permission-manager.ts")),
    import(url(packageRoot, "permission-resolver.ts")),
    import(url(packageRoot, "session-rules.ts")),
    import(url(packageRoot, "handlers/gates/tool-call-gate-pipeline.ts")),
    import(url(packageRoot, "handlers/gates/runner.ts")),
    import(url(packageRoot, "path-normalizer.ts")),
    import(url(packageRoot, "path/path-flavor.ts")),
    import(url(packageRoot, "tool-preview-formatter.ts")),
  ])) as [
    {
      PermissionManager: new (options: { agentDir: string }) => PermissionManagerLike;
    },
    {
      PermissionResolver: new (
        manager: PermissionManagerLike,
        sessionRules: SessionRulesLike,
      ) => PermissionResolverLike;
    },
    { SessionRules: new () => SessionRulesLike },
    {
      ToolCallGatePipeline: new (
        resolver: PermissionResolverLike,
        inputs: ToolCallGateInputsLike,
      ) => ToolCallGatePipelineLike;
    },
    {
      GateRunner: new (
        resolver: PermissionResolverLike,
        recorder: SessionRulesLike,
        prompter: PrompterLike,
        reporter: ReporterLike,
        isYoloEnabled: () => boolean,
      ) => GateRunnerLike;
    },
    {
      PathNormalizer: new (
        flavor: unknown,
        cwd: string,
      ) => PathNormalizerLike;
    },
    { posixPathFlavor: unknown },
    { resolveToolPreviewLimits: () => unknown },
  ];

  for (const [index, testCase] of BASELINE_PIPELINE_CASES.entries()) {
    const manager = new PermissionManager({ agentDir });
    manager.configureForCwd(repoRoot);
    const sessionRules = new SessionRules();
    const resolver = new PermissionResolver(manager, sessionRules);
    const normalizer = new PathNormalizer(posixPathFlavor, repoRoot);
    const prompts: Array<Record<string, unknown>> = [];
    const decisions: Array<Record<string, unknown>> = [];
    const logs: Array<{ event: string; details: Record<string, unknown> }> = [];

    const prompter = {
      async escalate(details: Record<string, unknown>) {
        prompts.push(details);
        return {
          approved: false,
          state: "denied" as const,
          decidedBy: { kind: "user" as const, via: "dialog" as const },
        };
      },
    };
    const reporter = {
      writeReviewLog(event: string, details: Record<string, unknown>) {
        logs.push({ event, details });
      },
      emitDecision(event: Record<string, unknown>) {
        decisions.push(event);
      },
    };
    const inputs = {
      getActiveSkillEntries: () => [],
      getInfrastructureReadDirs: () => [],
      getToolPreviewLimits: () => resolveToolPreviewLimits(),
      getPathNormalizer: () => normalizer,
      getShellToolAliases: () => undefined,
    };
    const pipeline = new ToolCallGatePipeline(resolver, inputs);
    const runner = new GateRunner(
      resolver,
      sessionRules,
      prompter,
      reporter,
      () => false,
    );
    const outcome = await pipeline.evaluate(
      {
        toolName: "bash",
        agentName: testCase.agentName ?? null,
        input: { command: testCase.command },
        toolCallId: `pipeline-${index}`,
        cwd: repoRoot,
      },
      runner,
    );

    if (testCase.expected === "allow") {
      expectAction(testCase, outcome, "allow");
      expectPromptCount(testCase, prompts, 0);
      continue;
    }

    expectAction(testCase, outcome, "block");
    if (testCase.expected === "ask") {
      expectPromptCount(testCase, prompts, 1);
      const payload = asRecord(prompts[0]?.payload);
      expectEvidence(testCase, asRecord(payload?.request));
      continue;
    }

    expectPromptCount(testCase, prompts, 0);
    const policyDecision = decisions.find(
      (event) => event.result === "deny" && event.resolution === "policy_deny",
    );
    const policyLog = logs.find(
      ({ event, details }) =>
        event === "permission_request.blocked" && details.resolution === "policy_denied",
    );
    expectEvidence(testCase, policyDecision ?? policyLog?.details);
  }
}
