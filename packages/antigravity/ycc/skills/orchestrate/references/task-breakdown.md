# Task Breakdown Template

## Contents

- Decomposition Principles
- Decomposition Strategies
- Decomposition Workflow
- Common Decomposition Patterns
- Decomposition Checklist
- Example: Full Decomposition
- Tips & Best Practices

Guide for decomposing complex tasks into parallelizable subtasks for agent orchestration.

## Decomposition Principles

### 1. Single Responsibility

Each subtask should have ONE clear purpose. Avoid combining multiple concerns.

**Good**: "Create user authentication service"
**Bad**: "Create user service, add tests, and write documentation"

### 2. Appropriate Granularity

Subtasks should be completable in one focused session (typically 1-3 files modified).

**Too Large**: "Implement entire payment system"
**Too Small**: "Add import statement to file.ts"
**Just Right**: "Create payment processing service with Stripe integration"

### 3. Clear Dependencies

Explicitly state what must be completed before each subtask.

**Good**: "Depends on: user-model (Task 1.1), auth-service (Task 1.2)"
**Bad**: "Depends on some other stuff"

### 4. Maximize Parallelism

Organize subtasks to maximize independent work that can run in parallel.

**Good Structure**:

- Batch 1: 4 independent foundation tasks
- Batch 2: 2 tasks depending on batch 1
- Batch 3: 1 integration task

**Bad Structure**:

- Task 1 → Task 2 → Task 3 → Task 4 → Task 5 (serial chain)

---

## Decomposition Strategies

### Strategy 1: By Feature Area

Break down by functional components of the feature.

**Example**: "Implement user authentication"

Subtasks:

1. Create user model and database schema
2. Implement password hashing and validation
3. Create JWT token generation and verification
4. Build login/logout endpoints
5. Add authentication middleware
6. Create password reset flow

**When to Use**: Clear functional boundaries, multiple components

---

### Strategy 2: By Technical Layer

Break down by application layers (frontend, backend, database, etc.).

**Example**: "Add favorites feature"

Subtasks:

1. **Database**: Create favorites table and migrations
2. **Backend**: Implement favorites API endpoints
3. **Frontend**: Create favorites UI component
4. **Testing**: Add integration tests for favorites
5. **Documentation**: Document favorites API

**When to Use**: Full-stack features, clear layer separation

---

### Strategy 3: By Cross-Cutting Concern

Break down by aspect (implementation, testing, docs, etc.).

**Example**: "Refactor authentication system"

Subtasks:

1. **Analysis**: Research current auth implementation and issues
2. **Refactor**: Update auth service with new patterns
3. **Migration**: Update all components using auth
4. **Testing**: Update test suite for new auth flow
5. **Documentation**: Update auth documentation

**When to Use**: Updates affecting multiple areas, refactoring work

---

### Strategy 4: By Data Flow

Break down following data/request flow through system.

**Example**: "Implement payment processing"

Subtasks:

1. Create payment intent on frontend
2. Send payment data to backend API
3. Process payment with Stripe service
4. Update order status in database
5. Send confirmation email
6. Return success to frontend

**When to Use**: Process-oriented features, API integrations

---

### Strategy 5: By Risk/Complexity

Tackle high-risk or complex items first, simple items in parallel.

**Example**: "Migrate to new database"

Subtasks:

1. **Critical**: Design new database schema (must be right)
2. **Parallel**: Write migration scripts for each table
3. **Parallel**: Update repository layer for new schema
4. **Integration**: Test migration with staging data
5. **Deployment**: Execute migration on production

**When to Use**: Risky changes, migrations, major refactors

---

## Decomposition Workflow

### Step 1: Understand the Task

Ask clarifying questions:

- What is the end goal?
- What components are involved?
- What already exists?
- What are the constraints?
- What's the priority?

### Step 2: Identify Major Components

List the major pieces needed:

- Frontend components
- Backend services
- Database changes
- API endpoints
- Tests
- Documentation

### Step 3: Map Dependencies

Create a dependency graph:

```
Task 1 (no deps)  →  Task 3 (depends on 1, 2)
Task 2 (no deps)  ↗
Task 4 (no deps)  →  Task 5 (depends on 4)
```

### Step 4: Organize into Batches

Group by execution order:

**Batch 1** (no dependencies): Tasks 1, 2, 4
**Batch 2** (depends on batch 1): Tasks 3, 5

### Step 5: Assign Agents

Match each subtask to optimal agent type:

- Frontend work → frontend-ui-developer
- Backend API → nodejs-backend-architect
- Database → db-modifier
- Tests → test-strategy-planner
- Docs → documentation-writer

### Step 6: Validate

Check each subtask:

- [ ] Clear, specific scope
- [ ] Single responsibility
- [ ] Dependencies explicit
- [ ] Agent type assigned
- [ ] Success criteria clear
- [ ] Non-overlapping with others

---

## Common Decomposition Patterns

### Pattern: CRUD Feature

**Template**:

1. Database schema/migrations (independent)
2. Backend API endpoints (depends on 1)
3. Frontend UI components (depends on 2)
4. Form validation (depends on 2)
5. Integration tests (depends on 2, 3)
6. API documentation (depends on 2)

### Pattern: Bug Fix

**Template**:

1. Root cause analysis (independent)
2. Implement fix (depends on 1)
3. Add regression tests (depends on 2)
4. Update documentation (depends on 2)

### Pattern: Refactoring

**Template**:

1. Analyze current implementation (independent)
2. Design new structure (depends on 1)
3. Refactor module A (depends on 2)
4. Refactor module B (depends on 2)
5. Refactor module C (depends on 2)
6. Update tests (depends on 3, 4, 5)
7. Update documentation (depends on 6)

### Pattern: API Integration

**Template**:

1. Research API documentation (independent)
2. Create API client/wrapper (depends on 1)
3. Implement service layer (depends on 2)
4. Add error handling (depends on 3)
5. Create integration tests (depends on 3)
6. Document API usage (depends on 2, 3)

### Pattern: Documentation Update

**Template**:

1. Audit existing documentation (independent)
2. Update API documentation (independent)
3. Update architecture docs (independent)
4. Update user guides (independent)
5. Create cross-links (depends on 2, 3, 4)

---

## Decomposition Checklist

Before finalizing task breakdown, verify:

### Scope Clarity

- [ ] Each subtask has clear, specific scope
- [ ] Boundaries between subtasks are well-defined
- [ ] No vague or ambiguous descriptions

### Independence & Dependencies

- [ ] Independent subtasks identified (can run in parallel)
- [ ] Dependencies explicitly stated for dependent tasks
- [ ] No circular dependencies
- [ ] Dependency chains are reasonable (prefer wide over deep)

### Agent Assignment

- [ ] Each subtask has appropriate agent type
- [ ] No duplicate work between agents
- [ ] Agent capabilities match subtask needs
- [ ] Context files identified for each agent

### Completeness

- [ ] All aspects of main task covered
- [ ] Nothing important missing
- [ ] Testing considerations included
- [ ] Documentation considerations included

### Feasibility

- [ ] Each subtask is appropriately sized
- [ ] Success criteria are achievable
- [ ] Technical approach is sound
- [ ] Resources/tools are available

---

## Example: Full Decomposition

**Task**: "Implement user favorites feature with persistence and sync"

### Analysis

- **Scope**: Full-stack feature (DB, backend, frontend)
- **Complexity**: Medium
- **Components**: Database, API, UI, sync logic
- **Strategy**: By technical layer

### Subtask Breakdown

#### Batch 1: Foundation (Independent)

**Task 1.1: Create Favorites Database Schema**

- Agent: db-modifier
- Dependencies: none
- Scope: Create favorites table, add user_id foreign key, indexes
- Files: migrations/001_create_favorites.sql
- Success: Table created with proper constraints

**Task 1.2: Design Favorites UI Component**

- Agent: frontend-ui-developer
- Dependencies: none
- Scope: Create favorites button, favorites list component
- Files: components/Favorites.tsx, components/FavoriteButton.tsx
- Success: UI components created (no API integration yet)

#### Batch 2: Core Implementation (Depends on Batch 1)

**Task 2.1: Implement Favorites API Endpoints**

- Agent: nodejs-backend-architect
- Dependencies: Task 1.1
- Scope: POST /favorites, DELETE /favorites/:id, GET /favorites
- Files: routes/favorites.ts, controllers/favorites.ts, services/favorites.ts
- Success: API endpoints functional with database

**Task 2.2: Add Sync Logic for Favorites**

- Agent: nodejs-backend-architect
- Dependencies: Task 1.1
- Scope: Real-time sync when user favorites across devices
- Files: services/sync.ts, websocket/favorites-sync.ts
- Success: Changes broadcast to connected clients

#### Batch 3: Integration (Depends on Batch 2)

**Task 3.1: Connect UI to API**

- Agent: frontend-ui-developer
- Dependencies: Task 1.2, Task 2.1
- Scope: Wire up favorites button/list to API calls
- Files: components/Favorites.tsx, components/FavoriteButton.tsx, hooks/useFavorites.ts
- Success: UI fully functional with persistence

**Task 3.2: Create Test Strategy**

- Agent: test-strategy-planner
- Dependencies: Task 2.1, Task 3.1
- Scope: Plan unit tests for API, integration tests for sync, e2e tests for UI
- Files: docs/test-plans/favorites-testing.md
- Success: Comprehensive test plan created

#### Batch 4: Polish (Depends on Batch 3)

**Task 4.1: Document Favorites API**

- Agent: api-docs-expert
- Dependencies: Task 2.1
- Scope: Document API endpoints with examples
- Files: docs/api/favorites.md
- Success: Complete API documentation

### Summary

- **Total Subtasks**: 7
- **Batches**: 4
- **Max Parallelism**: 2 (Batch 1)
- **Agents Used**: 4 different types

---

## Tips & Best Practices

1. **Start with the end goal**: What does success look like?
2. **Identify the critical path**: What must happen in order?
3. **Maximize parallel work**: Look for independent subtasks
4. **Consider the whole system**: Don't forget tests, docs, migrations
5. **Be specific**: "Update auth service" → "Add JWT token refresh logic to auth service"
6. **Think about handoffs**: What does the next agent need from this one?
7. **Plan for failure**: What happens if a subtask fails?
8. **Keep it balanced**: Avoid one huge subtask and many tiny ones
9. **Use existing patterns**: Follow decomposition patterns from similar past work
10. **Validate early**: Check subtask breakdown before deploying agents

---

_This template should be adapted based on the specific task, codebase, and constraints._
