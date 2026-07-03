// Clean, strict-typed React component. Passes tsc --noEmit, eslint ., vitest run.
export type Severity = "low" | "medium" | "high" | "critical";

export interface BadgeProps {
  readonly label: string;
  readonly severity: Severity;
}

const WEIGHTS: Record<Severity, number> = {
  low: 1,
  medium: 3,
  high: 7,
  critical: 10,
};

export function severityWeight(severity: Severity): number {
  return WEIGHTS[severity];
}

export function Badge({ label, severity }: BadgeProps): JSX.Element {
  return (
    <span data-testid="badge" data-severity={severity}>
      {label} ({severityWeight(severity)})
    </span>
  );
}
