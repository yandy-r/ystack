# Analysis Agent Prompts

## Contents

- Phase 2 crucible agents: ACH analyst, contradiction mapper
- Phase 3 strategic agents: tension mapper, pattern recognizer, negative space agent, innovation agent
- Usage instructions and expected outputs

These prompts deploy analysis agents for Phases 2-3 of the deep research process: crucible analysis and emergent insight generation.

---

## Phase 2 Agents: The Crucible

### Agent 1: ACH (Analysis of Competing Hypotheses) Analyst

**Subagent Type**: `general-purpose`

**Task Description**: Conduct Analysis of Competing Hypotheses

**Prompt Template**:

````
Conduct an Analysis of Competing Hypotheses (ACH) on "{{RESEARCH_SUBJECT}}" using all persona findings.

## Research Context

You have access to findings from 8 research personas:

1. Read: {{OUTPUT_DIR}}/objective.md
2. Read: {{OUTPUT_DIR}}/persona-findings/historian.md
3. Read: {{OUTPUT_DIR}}/persona-findings/contrarian.md
4. Read: {{OUTPUT_DIR}}/persona-findings/analogist.md
5. Read: {{OUTPUT_DIR}}/persona-findings/systems-thinker.md
6. Read: {{OUTPUT_DIR}}/persona-findings/journalist.md
7. Read: {{OUTPUT_DIR}}/persona-findings/archaeologist.md
8. Read: {{OUTPUT_DIR}}/persona-findings/futurist.md
9. Read: {{OUTPUT_DIR}}/persona-findings/negative-space.md

## Your Task: Analysis of Competing Hypotheses

ACH is a systematic method to evaluate multiple explanations and identify the most likely ones based on evidence.

### Step 1: Generate Hypotheses

Create 5+ mutually exclusive hypotheses about the research subject based on the persona findings. Hypotheses should:

- Cover the range of interpretations possible
- Be mutually exclusive (if one is true, others are false)
- Be specific enough to test against evidence
- Include conventional and contrarian views

### Step 2: Identify Evidence

Extract key pieces of evidence from all persona findings that could support or refute each hypothesis.

### Step 3: Evaluate Evidence vs Hypotheses

For each piece of evidence, assess:

- Which hypotheses it supports (consistent with)
- Which hypotheses it refutes (inconsistent with)
- Which hypotheses it doesn't affect (neutral)

Focus on **disconfirming evidence** - evidence that contradicts a hypothesis is more valuable than evidence that confirms it.

### Step 4: Assess Hypothesis Viability

After evaluating all evidence:

- Which hypotheses survive (have least disconfirming evidence)?
- Which hypotheses are eliminated (too much contradiction)?
- What's the relative strength of surviving hypotheses?

### Step 5: Identify Gaps

What evidence would help distinguish between remaining hypotheses?

## Output Format

Write your analysis to: {{OUTPUT_DIR}}/synthesis/crucible-analysis.md

Structure your report as:

```markdown
# Analysis of Competing Hypotheses: {{RESEARCH_SUBJECT}}

## Executive Summary

[2-3 sentences: Most viable hypotheses and key discriminating evidence]

## Hypotheses

### Hypothesis 1: [Statement]
**Description**: [Full explanation of this hypothesis]
**Proponents**: [Which personas or sources support this view]
**Implications**: [What follows if this is true]

### Hypothesis 2: [Statement]
[Same structure]

### Hypothesis 3: [Statement]
[Same structure]

### Hypothesis 4: [Statement]
[Same structure]

### Hypothesis 5: [Statement]
[Same structure]

[Add more if needed]

## Evidence Analysis

### Evidence vs Hypotheses Matrix

| Evidence | H1 | H2 | H3 | H4 | H5 | Source | Quality |
|----------|----|----|----|----|----|----|---------|
| [Evidence item] | C/I/N | C/I/N | C/I/N | C/I/N | C/I/N | [Persona] | H/M/L |

**Legend**: C = Consistent (supports), I = Inconsistent (refutes), N = Neutral (doesn't affect)
**Quality**: H = High confidence, M = Medium, L = Low/Speculative

### Critical Disconfirming Evidence

#### [Evidence that eliminates hypotheses]
- **Evidence**: [Description]
- **Refutes**: [Which hypotheses]
- **Why incompatible**: [Explanation]
- **Strength**: Strong/Moderate/Weak
- **Source**: [Which persona finding]

## Hypothesis Survival Analysis

### Eliminated Hypotheses

#### Hypothesis [X]: [Statement]
- **Disconfirming evidence count**: [Number]
- **Critical contradictions**: [Key evidence that eliminates it]
- **Why eliminated**: [Explanation]

### Surviving Hypotheses

#### Hypothesis [Y]: [Statement]
- **Disconfirming evidence count**: [Number - should be low]
- **Supporting evidence count**: [Number]
- **Viability**: High/Medium
- **Remaining questions**: [What's still uncertain]

#### Hypothesis [Z]: [Statement]
[Same structure]

## Relative Strength Assessment

### Most Viable: [Hypothesis]
- **Evidence score**: [Supporting vs Disconfirming]
- **Persona consensus**: [How many personas support]
- **Uncertainty level**: [What's still unknown]
- **Confidence**: High/Medium/Low

### Second Most Viable: [Hypothesis]
[Same structure]

## Discriminating Evidence Needed

To choose between surviving hypotheses, we need:

1. **[Type of evidence]**: [What it would show and which hypothesis it would support]
2. **[Type of evidence]**: [What it would show and which hypothesis it would support]
3. **[Type of evidence]**: [What it would show and which hypothesis it would support]

## Assumptions Challenged

### Common assumptions NOT supported by evidence:
- **Assumption**: [What people assume]
- **Evidence**: [What actually shows]
- **Implication**: [What this means]

## Key Insights

1. [Insight from hypothesis elimination process]
2. [Insight from surviving hypotheses]
3. [Insight from evidence contradictions]

## Methodology Notes

- **Total hypotheses generated**: [Count]
- **Hypotheses eliminated**: [Count]
- **Hypotheses surviving**: [Count]
- **Evidence items evaluated**: [Count]
- **Quality of evidence**: [Assessment]

## Confidence Assessment

- **Overall confidence in analysis**: High/Medium/Low
- **Main uncertainty sources**: [What reduces confidence]
- **Additional research needed**: [What would increase confidence]
```

**Critical**: Focus on disconfirming evidence - it's more valuable than confirming evidence. Eliminate hypotheses systematically.
````

---

### Agent 2: Contradiction Mapper

**Subagent Type**: `codebase-research-analyst`

**Task Description**: Map contradictions between persona findings

**Prompt Template**:

````
Map contradictions and disagreements between the 8 persona research findings for "{{RESEARCH_SUBJECT}}".

## Research Context

Read all persona findings:

1. {{OUTPUT_DIR}}/persona-findings/historian.md
2. {{OUTPUT_DIR}}/persona-findings/contrarian.md
3. {{OUTPUT_DIR}}/persona-findings/analogist.md
4. {{OUTPUT_DIR}}/persona-findings/systems-thinker.md
5. {{OUTPUT_DIR}}/persona-findings/journalist.md
6. {{OUTPUT_DIR}}/persona-findings/archaeologist.md
7. {{OUTPUT_DIR}}/persona-findings/futurist.md
8. {{OUTPUT_DIR}}/persona-findings/negative-space.md

## Your Task: Contradiction Mapping

Identify and analyze contradictions, disagreements, and tensions between persona findings.

### Types of Contradictions to Find:

1. **Factual contradictions**: Personas report conflicting facts
2. **Interpretive contradictions**: Same facts, different interpretations
3. **Temporal contradictions**: Past vs present vs future views conflict
4. **Perspective contradictions**: Different stakeholder views conflict
5. **Evidence contradictions**: Sources contradict each other

### Analysis Required:

- What exactly contradicts what?
- How significant is the contradiction?
- Can both be true in different contexts?
- Which has better evidence?
- What does the contradiction reveal?

## Output Format

Write your analysis to: {{OUTPUT_DIR}}/synthesis/contradiction-mapping.md

Structure your report as:

```markdown
# Contradiction Mapping: {{RESEARCH_SUBJECT}}

## Executive Summary

[2-3 sentences: Most significant contradictions and what they reveal]

## Major Contradictions

### Contradiction 1: [Topic]

**Personas involved**: [Which personas disagree]

**Position A** ([Persona]):
- **Claim**: [What they say]
- **Evidence**: [What supports it]
- **Source quality**: High/Medium/Low
- **Quote**: "[Key excerpt]"

**Position B** ([Persona]):
- **Claim**: [What they say]
- **Evidence**: [What supports it]
- **Source quality**: High/Medium/Low
- **Quote**: "[Key excerpt]"

**Analysis**:
- **Type**: Factual/Interpretive/Temporal/Perspective/Evidence
- **Reconcilable?**: Yes/No/Partially
- **Resolution approach**: [How to resolve or which is stronger]
- **Significance**: High/Medium/Low
- **What it reveals**: [Insight from the contradiction]

### Contradiction 2: [Topic]
[Same structure]

### Contradiction 3: [Topic]
[Same structure]

## Contradiction Patterns

### Temporal Tensions
- **Past (Historian/Archaeologist) vs Future (Futurist)**: [Key disagreements]
- **What this reveals**: [Insight]

### Critical vs Optimistic Views
- **Contrarian vs others**: [Where Contrarian challenges consensus]
- **Validity**: [Assessment of contrarian critiques]

### Theory vs Practice
- **Systems Thinker vs Journalist**: [Abstract theory vs current reality gaps]
- **Implications**: [What this means]

## Contradiction Severity Matrix

| Contradiction | Severity | Resolvability | Evidence Quality A | Evidence Quality B |
|---------------|----------|---------------|-------------------|-------------------|
| [Topic] | High/Med/Low | Easy/Hard/Impossible | H/M/L | H/M/L |

## Irreconcilable Contradictions

### [Contradiction that cannot be resolved]
- **Why irreconcilable**: [Explanation]
- **Implication**: [What this means for the research]
- **Further research needed**: [What would help]

## Productive Tensions

Contradictions that reveal important insights rather than errors:

### [Tension]
- **Personas**: [Which disagree]
- **Why productive**: [What the tension illuminates]
- **Both true?**: [How both perspectives might be valid]
- **Insight**: [What we learn from the tension]

## Evidence Quality Conflicts

When evidence quality differs between contradicting claims:

### [Topic with evidence quality mismatch]
- **High-quality evidence says**: [Position]
- **Low-quality evidence says**: [Position]
- **Resolution**: [Go with better evidence]

## Context-Dependent Truths

Apparent contradictions that are both true in different contexts:

### [Context-dependent claim]
- **True when**: [Context A]
- **False when**: [Context B]
- **Key variable**: [What determines which is true]

## Contradiction Insights

What the pattern of contradictions reveals:

1. **[Insight]**: [What disagreements tell us about the field]
2. **[Insight]**: [What contradictions reveal about knowledge gaps]
3. **[Insight]**: [What tensions indicate about future directions]

## Recommended Resolution Priorities

1. **[Contradiction to resolve first]**: [Why priority and how to resolve]
2. **[Second priority]**: [Why and how]
3. **[Third priority]**: [Why and how]

## Unresolved Questions

Contradictions that need additional research:

- **[Question]**: [What evidence would resolve this]
- **[Question]**: [What evidence would resolve this]

## Key Insights

1. [Insight from major contradictions]
2. [Insight from contradiction patterns]
3. [Insight from productive tensions]

## Summary Statistics

- **Total contradictions identified**: [Count]
- **Major (high severity)**: [Count]
- **Resolvable**: [Count]
- **Irreconcilable**: [Count]
- **Productive tensions**: [Count]
```

**Critical**: Don't smooth over contradictions. Explore what they reveal about the subject. Some contradictions are more illuminating than agreements.
````

---

## Phase 3 Agents: Emergent Insight Generation

### Agent 1: Tension Mapper

**Subagent Type**: `codebase-research-analyst`

**Task Description**: Identify maximum disagreement points

**Prompt Template**:

````
Identify points of maximum tension and disagreement across all research findings for "{{RESEARCH_SUBJECT}}".

## Research Context

Read all synthesis files:

1. {{OUTPUT_DIR}}/persona-findings/*.md (all 8 files)
2. {{OUTPUT_DIR}}/synthesis/crucible-analysis.md
3. {{OUTPUT_DIR}}/synthesis/contradiction-mapping.md

## Your Task: Tension Mapping

Find where research reveals the deepest disagreements, unresolved debates, and conceptual tensions.

### Focus Areas:

1. **Stakeholder tensions**: Who wants opposite things?
2. **Value tensions**: What values conflict?
3. **Trade-off tensions**: What can't be optimized simultaneously?
4. **Temporal tensions**: What conflicts arise across timeframes?
5. **Conceptual tensions**: What fundamental concepts contradict?

## Output Format

Write your analysis to: {{OUTPUT_DIR}}/synthesis/tension-mapping.md

```markdown
# Tension Mapping: {{RESEARCH_SUBJECT}}

## Executive Summary
[2-3 sentences: Most significant tensions identified]

## Maximum Disagreement Points

### Tension 1: [Name]
- **Type**: Stakeholder/Value/Trade-off/Temporal/Conceptual
- **Description**: [What's in tension]
- **Side A**: [Position/viewpoint]
- **Side B**: [Opposite position/viewpoint]
- **Severity**: High/Medium/Low
- **Resolvable?**: Yes/No/Partially
- **Insight**: [What this tension reveals]

[Repeat for other tensions]

## Stakeholder Tensions

[Map who wants what and where interests conflict]

## Value Tensions

[Where different values create irreconcilable conflicts]

## Trade-off Tensions

[What cannot be optimized simultaneously]

## Key Insights

1. [Insight from tension analysis]
2. [Insight from disagreement patterns]
3. [Insight from unresolvable conflicts]
```
````

---

### Agent 2: Pattern Recognizer

**Subagent Type**: `general-purpose`

**Task Description**: Find unexpected patterns and connections

**Prompt Template**:

````
Identify unexpected patterns, historical echoes, and surprising connections across all research findings for "{{RESEARCH_SUBJECT}}".

## Research Context

Read all research artifacts:

1. All persona findings
2. All synthesis files
3. Evidence verification log (if exists)

## Your Task: Pattern Recognition

Find patterns that weren't obvious from individual persona research but emerge from the totality of findings.

### Pattern Types:

1. **Historical echoes**: Current situations resembling past
2. **Cross-domain patterns**: Similar patterns in different areas
3. **Cyclical patterns**: Recurring themes or cycles
4. **Convergence patterns**: Different paths leading to same conclusion
5. **Divergence patterns**: One cause, multiple effects

## Output Format

Write your analysis to: {{OUTPUT_DIR}}/synthesis/pattern-recognition.md

```markdown
# Pattern Recognition: {{RESEARCH_SUBJECT}}

## Executive Summary
[2-3 sentences: Most surprising patterns discovered]

## Unexpected Patterns

### Pattern 1: [Name]
- **Type**: Historical/Cross-domain/Cyclical/Convergence/Divergence
- **Description**: [What the pattern is]
- **Evidence**: [Where it appears]
- **Significance**: [Why it matters]
- **Surprise factor**: [Why unexpected]

[Repeat for other patterns]

## Historical Echoes

[Where history is repeating or rhyming]

## Cross-Domain Parallels

[Patterns appearing across different domains]

## Key Insights

1. [Insight from pattern analysis]
2. [Insight from unexpected connections]
3. [Insight from historical echoes]
```
````

---

### Agent 3: Negative Space Agent

**Subagent Type**: `codebase-research-analyst`

**Task Description**: Document unanswered questions and gaps

**Prompt Template**:

````
Synthesize unanswered questions, research gaps, and areas of uncertainty from all research findings for "{{RESEARCH_SUBJECT}}".

## Research Context

Read all research artifacts to identify what remains unknown.

## Your Task: Negative Space Synthesis

Compile all gaps, uncertainties, and unanswered questions. Prioritize by importance.

## Output Format

Write your analysis to: {{OUTPUT_DIR}}/synthesis/negative-space.md

```markdown
# Negative Space Analysis: {{RESEARCH_SUBJECT}}

## Executive Summary
[2-3 sentences: Most critical gaps and unanswered questions]

## Critical Unanswered Questions

### [Question]
- **Why critical**: [Impact of not knowing]
- **Current status**: [What we do know]
- **What's needed**: [What research would answer this]
- **Priority**: High/Medium/Low

[Repeat for other questions]

## Research Gaps by Category

### Empirical Gaps
[What data doesn't exist]

### Theoretical Gaps
[What frameworks are missing]

### Practical Gaps
[What implementation knowledge is absent]

## Key Insights

1. [Insight from gap analysis]
2. [Insight from unanswered questions]
3. [Insight from uncertainty patterns]
```
````

---

### Agent 4: Innovation Agent

**Subagent Type**: `general-purpose`

**Task Description**: Generate novel hypotheses from persona combinations

**Prompt Template**:

````
Generate novel hypotheses and innovative insights by combining findings from different research personas for "{{RESEARCH_SUBJECT}}".

## Research Context

Read all research artifacts to find novel combinations and insights.

## Your Task: Innovation Synthesis

Combine insights from different personas to generate novel hypotheses, ideas, or approaches that didn't appear in any single persona research.

### Innovation Strategies:

1. **Combine contradictions**: What if both opposing views are true?
2. **Cross-temporal**: Combine past solutions with future technology
3. **Cross-domain transfer**: Apply insights from one domain to another
4. **System + Critique**: Combine systems thinking with contrarian critiques
5. **Historical + Futurist**: What old approaches could work with future tech?

## Output Format

Write your analysis to: {{OUTPUT_DIR}}/synthesis/innovation.md

```markdown
# Innovation Synthesis: {{RESEARCH_SUBJECT}}

## Executive Summary
[2-3 sentences: Most promising novel insights]

## Novel Hypotheses

### Hypothesis 1: [Statement]
- **Combines**: [Which personas/insights]
- **Rationale**: [Why this combination is interesting]
- **Testable prediction**: [What would validate this]
- **Potential impact**: [If true, what changes]
- **Feasibility**: High/Medium/Low

[Repeat for other hypotheses]

## Innovative Approaches

[Novel solutions or methods derived from synthesis]

## Unexpected Insights

[Insights that emerged from combining different perspectives]

## Key Insights

1. [Most valuable novel insight]
2. [Second most valuable insight]
3. [Third most valuable insight]
```
````

---

## Usage Instructions

### Phase 2 Deployment (Crucible Analysis)

Deploy both agents in **SINGLE message** with **TWO Agent tool calls**:

1. **ACH Analyst** (`general-purpose`) -> crucible-analysis.md
2. **Contradiction Mapper** (`codebase-research-analyst`) -> contradiction-mapping.md

### Phase 3 Deployment (Emergent Insights)

Deploy all four agents in **SINGLE message** with **FOUR Agent tool calls**:

1. **Tension Mapper** (`codebase-research-analyst`) -> tension-mapping.md
2. **Pattern Recognizer** (`general-purpose`) -> pattern-recognition.md
3. **Negative Space Agent** (`codebase-research-analyst`) -> negative-space.md
4. **Innovation Agent** (`general-purpose`) -> innovation.md

## Variable Reference

| Variable               | Description           | Example                          |
| ---------------------- | --------------------- | -------------------------------- |
| `{{RESEARCH_SUBJECT}}` | The research topic    | `AI model deployment strategies` |
| `{{OUTPUT_DIR}}`       | Output directory path | `research/ai-deployment`         |

## Expected Outputs

### Crucible Analysis Files Should

- Systematically evaluate competing explanations
- Focus on disconfirming evidence
- Map contradictions without smoothing them over
- Be evidence-based and rigorous

### Emergent Insight Files Should

- Identify patterns not visible in individual personas
- Generate novel hypotheses from combinations
- Document critical gaps and questions
- Be creative but grounded in research
