// MUTATION FIXTURE — TS compile fault (reason code TS_COMPILE_FAIL). Overlaid into
// src/ by the validation driver. Passes a number where the component's severity
// prop expects a Severity string union: TypeScript error TS2322/TS2769.
import { Badge } from "./Badge.js";

export function Broken(): JSX.Element {
  return <Badge label="bad" severity={42} />;
}
