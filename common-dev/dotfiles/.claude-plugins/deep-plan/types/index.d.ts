export type DeepPlanFacet = 'off' | 'plan' | 'execute'

export type DeepPlanPlan = {
  path: string
  // Bumped by every write_plan and edit_plan.
  version: number
  // The version plan-reviewer last reviewed; 0 for never.
  reviewedVersion: number
}

declare module 'claude-code' {
  interface PluginState {
    'deep-plan': {
      facet: DeepPlanFacet
      plan: DeepPlanPlan | null
      isClearPending: boolean
      isClearing: boolean
    }
  }
}
