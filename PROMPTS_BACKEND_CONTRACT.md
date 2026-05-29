# Prompts Backend Contract

Contract version: `2026-02-15.prompts.v1`
Endpoint: `POST /prompts`

## Request (from app)

```json
{
  "contract_version": "2026-02-15.prompts.v1",
  "transcript": "...full transcript...",
  "duration": 3420.5,
  "count": 12,
  "strategy": "episode_synthesis",
  "model": {
    "analysis_mode": "frontier_max",
    "reasoning_budget": "max",
    "model_preference": ["gpt-5", "o3", "o4-mini-high"]
  },
  "generation": {
    "global_synthesis_required": true,
    "candidate_multiplier": 4,
    "pipeline": [
      "full_episode_analysis",
      "multi_pass_candidate_generation",
      "judge_reranking",
      "evidence_grounding",
      "self_critique_revision"
    ],
    "constraints": [
      "No sponsor, ad, shoutout, promo, or housekeeping content",
      "Questions must not be repetitive",
      "Avoid generic summary questions",
      "Prioritize questions that require synthesis across opening, middle, and closing sections",
      "Each final answer must include cross-episode evidence"
    ]
  },
  "quality": {
    "question_quality": "frontier_expert",
    "question_style": "nuanced, non-generic, naturally-phrased, only-answerable-from-full-episode-context",
    "answer_grounding": "expected answers must be derived from podcast transcript content only",
    "answer_quality": "specific, high-signal, cites concrete claims/evidence/tradeoffs and connects earlier/later episode sections",
    "scoring_rubric": [
      "importance_to_listener",
      "episode_specificity",
      "cross_episode_synthesis",
      "answerability_from_transcript",
      "depth_and_non_genericity",
      "factual_grounding"
    ]
  },
  "output": {
    "include_candidates": true,
    "include_evidence": true,
    "include_scores": true,
    "include_diagnostics": true
  }
}
```

## Response (recommended)

```json
{
  "contract_version": "2026-02-15.prompts.v1",
  "run": {
    "model_used": "gpt-5",
    "strategy": "episode_synthesis",
    "candidate_count": 48,
    "selected_count": 12
  },
  "prompts": [
    {
      "time": 412.6,
      "question": "How does the speaker's closing argument about incentive design revise their opening claim about fairness?",
      "expected_answer": "Earlier in the episode, they frame fairness as equal treatment, but later they argue fairness depends on incentive alignment under constraints. The closing section reframes fairness as outcome-aware design rather than identical process.",
      "scores": {
        "overall": 0.91,
        "importance_to_listener": 0.9,
        "episode_specificity": 0.95,
        "cross_episode_synthesis": 0.93,
        "grounding": 0.88
      },
      "evidence": [
        {
          "start_seconds": 55.1,
          "end_seconds": 77.3,
          "quote": "..."
        },
        {
          "start_seconds": 397.2,
          "end_seconds": 425.0,
          "quote": "..."
        }
      ],
      "passes_quality_gates": true
    }
  ],
  "diagnostics": {
    "rejected_generic_questions": 21,
    "duplicate_questions_removed": 10,
    "notes": [
      "Enforced cross-episode synthesis for all selected prompts"
    ]
  }
}
```

## Backward compatibility accepted by app

The app also accepts:
- Top-level array: `[ { "time": ..., "question": ..., "expectedAnswer": ... } ]`
- Envelope: `{ "prompts": [ ... ] }`
- Nested envelope: `{ "data": { "prompts": [ ... ] } }`

`expected_answer` and `expectedAnswer` are both supported.

## Quality expectations for backend

- Must prioritize questions that require opening/middle/closing synthesis.
- Must include transcript-grounded expected answers.
- Should provide evidence spans and overall score per prompt.
- Should set `passes_quality_gates=false` for weak/generic items.
