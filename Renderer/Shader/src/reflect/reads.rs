// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Which uniform block members a stage can read: the members whose value can reach anything the
//! stage produces. Not part of spec D's reflection; an addition the engine reads when it is
//! present and treats as "every declared member is read" when it is absent.
//!
//! A shader often computes a value from a uniform and never uses it: `genericimage4.vert` forms
//! `g_EyePosition - worldPos` whatever its combos, and only its lighting and fog paths read the
//! result. The block still declares the member and the translated text still names it, so the
//! declaration alone says nothing about whether the uniform reaches the picture. This analysis
//! answers that on the naga module that is translated, as a dead-code elimination would:
//!
//! - **What a stage produces** is the entry point's return value (its outputs, which naga's GLSL
//!   front end loads from private variables) and every branch, switch and loop condition of a
//!   function the entry point reaches, so whether a `discard`, a `return` or a write runs is
//!   always counted as used.
//! - **A used value** uses its operands. Loading a variable uses every write to it anywhere in the
//!   reached functions, its initializer, and the index of every element written; a variable is
//!   one unit, never split by element. A call's result uses the callee's returned values; a
//!   parameter the callee uses uses the argument at every call; a pointer argument joins the
//!   caller's variable and the callee's parameter both ways.
//! - **A member is read** when a used expression selects it from the block; a use of the block as
//!   a whole reads every member.
//!
//! The answer only ever over-states what is read. Any statement or expression form the analysis
//! does not model (atomics, image stores, subgroup and ray-query operations, a pointer that is
//! not rooted in a variable or parameter) gives no answer, which costs the host nothing but the
//! saving.

use std::collections::{BTreeMap, BTreeSet, HashSet};

use naga::{AddressSpace, Block, Expression, Function, GlobalVariable, Handle, LocalVariable, Module, Statement, TypeInner};

/// Deepest nesting of blocks, and longest pointer chain, followed.
const MAX_DEPTH: usize = 256;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
enum Func {
    Entry,
    Function(Handle<Function>),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
enum Var {
    Global(Handle<GlobalVariable>),
    Local(Func, Handle<LocalVariable>),
    Argument(Func, u32),
}

struct Call {
    callee: Handle<Function>,
    arguments: Vec<Handle<Expression>>,
}

/// What one reached function contributes: its writes, calls, returned values and conditions.
#[derive(Default)]
struct Facts {
    stores: Vec<(Handle<Expression>, Handle<Expression>)>,
    calls: Vec<Call>,
    returns: Vec<Handle<Expression>>,
    conditions: Vec<Handle<Expression>>,
}

/// The names of the uniform block members the entry point `entry` can read, or `None` when the
/// module holds a form this analysis does not model.
pub(crate) fn read_members(module: &Module, entry: usize) -> Option<BTreeSet<String>> {
    Analysis::new(module, entry)?.run()
}

struct Analysis<'a> {
    module: &'a Module,
    entry: &'a naga::EntryPoint,
    facts: BTreeMap<Func, Facts>,
    used: BTreeMap<Func, Vec<bool>>,
    vars: HashSet<Var>,
    returning: HashSet<Func>,
    members: BTreeMap<Handle<GlobalVariable>, BTreeSet<u32>>,
    whole: BTreeSet<Handle<GlobalVariable>>,
    changed: bool,
}

impl<'a> Analysis<'a> {
    /// Collects the facts of every function the entry point reaches.
    fn new(module: &'a Module, entry: usize) -> Option<Analysis<'a>> {
        let mut analysis = Analysis {
            module,
            entry: module.entry_points.get(entry)?,
            facts: BTreeMap::new(),
            used: BTreeMap::new(),
            vars: HashSet::new(),
            returning: HashSet::from([Func::Entry]),
            members: BTreeMap::new(),
            whole: BTreeSet::new(),
            changed: false,
        };
        let mut pending = vec![Func::Entry];
        while let Some(func) = pending.pop() {
            if analysis.facts.contains_key(&func) {
                continue;
            }
            let f = analysis.function(func);
            if f.expressions.iter().any(|(_, e)| unmodelled(e)) {
                return None;
            }
            let mut facts = Facts::default();
            collect(&f.body, &mut facts, 0)?;
            pending.extend(facts.calls.iter().map(|c| Func::Function(c.callee)));
            analysis.used.insert(func, vec![false; f.expressions.len()]);
            analysis.facts.insert(func, facts);
        }
        Some(analysis)
    }

    fn function(&self, func: Func) -> &'a Function {
        match func {
            Func::Entry => &self.entry.function,
            Func::Function(handle) => &self.module.functions[handle],
        }
    }

    fn is_block(&self, global: Handle<GlobalVariable>) -> bool {
        self.module.global_variables[global].space == AddressSpace::Uniform
    }

    fn mark(&mut self, func: Func, handle: Handle<Expression>) {
        let used = self.used.get_mut(&func).expect("a reached function");
        if !used[handle.index()] {
            used[handle.index()] = true;
            self.changed = true;
        }
    }

    fn mark_var(&mut self, var: Var) {
        if self.vars.insert(var) {
            self.changed = true;
        }
    }

    fn run(mut self) -> Option<BTreeSet<String>> {
        // What every stage produces regardless of what it computes.
        let funcs: Vec<Func> = self.facts.keys().copied().collect();
        for &func in &funcs {
            let conditions = self.facts[&func].conditions.clone();
            for c in conditions {
                self.mark(func, c);
            }
        }
        loop {
            self.changed = false;
            for &func in &funcs {
                self.propagate(func)?;
            }
            for &func in &funcs {
                self.link(func)?;
            }
            if !self.changed {
                break;
            }
        }
        let mut names = BTreeSet::new();
        for (handle, var) in self.module.global_variables.iter() {
            if var.space != AddressSpace::Uniform {
                continue;
            }
            let TypeInner::Struct { members, .. } = &self.module.types[var.ty].inner else {
                // A uniform that is not a block names no member; one in use is not modelled.
                if self.whole.contains(&handle) || self.members.contains_key(&handle) {
                    return None;
                }
                continue;
            };
            let all = self.whole.contains(&handle);
            let selected = self.members.get(&handle);
            for (index, member) in members.iter().enumerate() {
                if all || selected.is_some_and(|s| s.contains(&(index as u32))) {
                    names.insert(member.name.clone()?);
                }
            }
        }
        Some(names)
    }

    /// One back-to-front pass over a function's expressions: an expression only refers to the
    /// ones before it, so a used expression's operands are marked before they are visited.
    fn propagate(&mut self, func: Func) -> Option<()> {
        let f = self.function(func);
        for (handle, expression) in f.expressions.iter().rev() {
            if !self.used[&func][handle.index()] {
                continue;
            }
            match *expression {
                Expression::AccessIndex { base, index } => match f.expressions[base] {
                    Expression::GlobalVariable(g) if self.is_block(g) => {
                        if self.members.entry(g).or_default().insert(index) {
                            self.changed = true;
                        }
                    }
                    _ => self.mark(func, base),
                },
                Expression::GlobalVariable(g) => {
                    if self.is_block(g) {
                        if self.whole.insert(g) {
                            self.changed = true;
                        }
                    } else {
                        self.mark_var(Var::Global(g));
                    }
                }
                Expression::LocalVariable(l) => {
                    self.mark_var(Var::Local(func, l));
                    if let Some(init) = f.local_variables[l].init {
                        self.mark(func, init);
                    }
                }
                Expression::FunctionArgument(i) => self.mark_var(Var::Argument(func, i)),
                Expression::CallResult(callee) => {
                    if self.returning.insert(Func::Function(callee)) {
                        self.changed = true;
                    }
                }
                ref other => {
                    for operand in operands(other)? {
                        self.mark(func, operand);
                    }
                }
            }
        }
        Some(())
    }

    /// Writes into used variables, arguments of used parameters, and returned values of functions
    /// whose result is used.
    fn link(&mut self, func: Func) -> Option<()> {
        let f = self.function(func);
        let facts = &self.facts[&func];
        let mut marks = Vec::new();
        let mut vars = Vec::new();
        for &(pointer, value) in &facts.stores {
            let var = root(f, func, pointer, 0)?;
            if self.vars.contains(&var) {
                marks.push(pointer);
                marks.push(value);
            }
        }
        for call in &facts.calls {
            let callee = Func::Function(call.callee);
            let parameters = &self.module.functions[call.callee].arguments;
            for (j, &argument) in call.arguments.iter().enumerate() {
                let parameter = Var::Argument(callee, j as u32);
                if self.vars.contains(&parameter) {
                    marks.push(argument);
                }
                let pointer = parameters
                    .get(j)
                    .is_some_and(|p| matches!(self.module.types[p.ty].inner, TypeInner::Pointer { .. }));
                if pointer && self.vars.contains(&root(f, func, argument, 0)?) {
                    vars.push(parameter);
                }
            }
        }
        if self.returning.contains(&func) {
            marks.extend(facts.returns.iter().copied());
        }
        for handle in marks {
            self.mark(func, handle);
        }
        for var in vars {
            self.mark_var(var);
        }
        Some(())
    }
}

/// Records a block's writes, calls, returned values and conditions; `None` on a statement the
/// analysis does not model.
fn collect(block: &Block, facts: &mut Facts, depth: usize) -> Option<()> {
    if depth > MAX_DEPTH {
        return None;
    }
    for statement in block.iter() {
        match statement {
            Statement::Emit(_) | Statement::Break | Statement::Continue | Statement::Kill => {}
            Statement::ControlBarrier(_) | Statement::MemoryBarrier(_) => {}
            Statement::Block(b) => collect(b, facts, depth + 1)?,
            Statement::If { condition, accept, reject } => {
                facts.conditions.push(*condition);
                collect(accept, facts, depth + 1)?;
                collect(reject, facts, depth + 1)?;
            }
            Statement::Switch { selector, cases } => {
                facts.conditions.push(*selector);
                for case in cases {
                    collect(&case.body, facts, depth + 1)?;
                }
            }
            Statement::Loop { body, continuing, break_if } => {
                facts.conditions.extend(*break_if);
                collect(body, facts, depth + 1)?;
                collect(continuing, facts, depth + 1)?;
            }
            Statement::Return { value } => facts.returns.extend(*value),
            Statement::Store { pointer, value } => facts.stores.push((*pointer, *value)),
            Statement::Call { function, arguments, .. } => {
                facts.calls.push(Call { callee: *function, arguments: arguments.clone() })
            }
            _ => return None,
        }
    }
    Some(())
}

/// The variable or parameter a pointer expression points into, through element accesses.
fn root(f: &Function, func: Func, pointer: Handle<Expression>, depth: usize) -> Option<Var> {
    if depth > MAX_DEPTH {
        return None;
    }
    match f.expressions[pointer] {
        Expression::GlobalVariable(g) => Some(Var::Global(g)),
        Expression::LocalVariable(l) => Some(Var::Local(func, l)),
        Expression::FunctionArgument(i) => Some(Var::Argument(func, i)),
        Expression::Access { base, .. } | Expression::AccessIndex { base, .. } => root(f, func, base, depth + 1),
        _ => None,
    }
}

/// Expression forms whose value comes from a statement this analysis does not model.
fn unmodelled(expression: &Expression) -> bool {
    matches!(
        expression,
        Expression::AtomicResult { .. }
            | Expression::WorkGroupUniformLoadResult { .. }
            | Expression::RayQueryVertexPositions { .. }
            | Expression::RayQueryProceedResult
            | Expression::RayQueryGetIntersection { .. }
            | Expression::SubgroupBallotResult
            | Expression::SubgroupOperationResult { .. }
            | Expression::CooperativeLoad { .. }
            | Expression::CooperativeMultiplyAdd { .. }
    )
}

/// The expressions a value-producing expression reads; `None` for a form not modelled. The
/// variable, parameter, call-result and block-member forms are handled by the caller.
fn operands(expression: &Expression) -> Option<Vec<Handle<Expression>>> {
    use naga::SampleLevel;
    Some(match *expression {
        Expression::Literal(_) | Expression::Constant(_) | Expression::Override(_) | Expression::ZeroValue(_) => {
            Vec::new()
        }
        Expression::Compose { ref components, .. } => components.clone(),
        Expression::Access { base, index } => vec![base, index],
        Expression::AccessIndex { base, .. } => vec![base],
        Expression::Splat { value, .. } => vec![value],
        Expression::Swizzle { vector, .. } => vec![vector],
        Expression::Load { pointer } => vec![pointer],
        Expression::ImageSample { image, sampler, coordinate, array_index, offset, ref level, depth_ref, .. } => {
            let mut out = vec![image, sampler, coordinate];
            out.extend(array_index);
            out.extend(offset);
            match *level {
                SampleLevel::Auto | SampleLevel::Zero => {}
                SampleLevel::Exact(e) | SampleLevel::Bias(e) => out.push(e),
                SampleLevel::Gradient { x, y } => out.extend([x, y]),
            }
            out.extend(depth_ref);
            out
        }
        Expression::ImageLoad { image, coordinate, array_index, sample, level } => {
            let mut out = vec![image, coordinate];
            out.extend(array_index);
            out.extend(sample);
            out.extend(level);
            out
        }
        Expression::ImageQuery { image, ref query } => {
            let mut out = vec![image];
            if let naga::ImageQuery::Size { level: Some(level) } = *query {
                out.push(level);
            }
            out
        }
        Expression::Unary { expr, .. } => vec![expr],
        Expression::Binary { left, right, .. } => vec![left, right],
        Expression::Select { condition, accept, reject } => vec![condition, accept, reject],
        Expression::Derivative { expr, .. } => vec![expr],
        Expression::Relational { argument, .. } => vec![argument],
        Expression::Math { arg, arg1, arg2, arg3, .. } => {
            let mut out = vec![arg];
            out.extend(arg1);
            out.extend(arg2);
            out.extend(arg3);
            out
        }
        Expression::As { expr, .. } => vec![expr],
        Expression::ArrayLength(e) => vec![e],
        _ => return None,
    })
}

#[cfg(test)]
mod tests;
