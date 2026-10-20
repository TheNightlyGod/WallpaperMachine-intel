use std::collections::BTreeSet;

use smol_str::SmolStr;

use super::ScopedDeclarationFacts;
use crate::{
    codegen::{
        DeclarationPlan, LegacyTypeName,
        declarations::PlannedDeclaration,
        expressions::analysis::{
            FunctionCallRange, Lvalue, ScalarExpressionFacts, ScalarType,
            VectorExpressionAnalyzer, VectorExpressionFacts, VectorExpressionType, VectorWidth,
        },
    },
    tokenizer::{FunctionSignatureFact, TokenCursor, TypedTokenFacts},
};

/// Known scalar and vector declaration facts.
#[derive(Default)]
pub(super) struct VectorTypeBindings<'src> {
    /// Bindings in source order.
    pub bindings: Vec<TypeBinding>,
    /// Function return types in source order.
    pub functions: Vec<FunctionTypeBinding>,
    /// Source lifetime marker for declaration source slices that still come
    /// from syntax records.
    pub source: std::marker::PhantomData<&'src str>,
}

impl VectorTypeBindings<'_> {
    /// Builds type bindings from source-scoped declarations and generated
    /// top-level declarations planned by the legalizer.
    #[expect(
        clippy::single_call_fn,
        reason = "constructor keeps VectorTypeBindings assembly centralized"
    )]
    pub(super) fn new(
        scoped_facts: &ScopedDeclarationFacts,
        declarations: &DeclarationPlan<'_>,
        tokens: TokenCursor<'_>,
    ) -> Self {
        let mut bindings = declarations
            .type_bindings()
            .map(|binding| TypeBinding {
                name: SmolStr::new(binding.name()),
                ty: BindingType::classify(binding.ty()),
                component: ComponentKind::classify(binding.ty()),
                visible_start: 0,
                scope_end: usize::MAX,
            })
            .collect::<Vec<_>>();
        bindings.extend(declarations.texture_samplers().map(|sampler| TypeBinding {
            name: SmolStr::new(sampler.texture_name),
            ty: BindingType::Sampler2D,
            component: ComponentKind::Other,
            visible_start: 0,
            scope_end: usize::MAX,
        }));
        // Rewritten globals already have their emitted types above. Their
        // original source types must not shadow interface width overrides,
        // while function parameters and local declarations still must.
        bindings.extend(Vec::from(scoped_facts).into_iter().filter(|binding| {
            let name_span = tokens[binding.visible_start - 1].span();
            !declarations.entries.iter().any(|entry| {
                matches!(
                    &entry.kind,
                    PlannedDeclaration::Interface(_) | PlannedDeclaration::UniformMember(_)
                ) && entry.span.start() <= name_span.start()
                    && name_span.end() <= entry.span.end()
            })
        }));
        Self {
            bindings,
            functions: Vec::new(),
            source: std::marker::PhantomData,
        }
    }

    /// Looks up the nearest visible binding by name at `use_index`.
    pub(super) fn lookup(&self, name: &str, use_index: usize) -> Option<BindingType> {
        self.visible(name, use_index).map(|binding| binding.ty)
    }

    /// Marks the `int` declarators that the control-flow step repair rewrites
    /// to `float`, so a later call on one of them selects the float overload.
    pub(super) fn retype_float_steps(&mut self, name_indices: &BTreeSet<usize>) {
        for binding in &mut self.bindings {
            if binding
                .visible_start
                .checked_sub(1)
                .is_some_and(|name| name_indices.contains(&name))
            {
                binding.component = ComponentKind::Float;
            }
        }
    }

    /// Looks up the component kind of the nearest visible binding.
    pub(super) fn component(&self, name: &str, use_index: usize) -> Option<ComponentKind> {
        self.visible(name, use_index).map(|binding| binding.component)
    }

    /// Returns the nearest binding of `name` visible at `use_index`.
    fn visible(&self, name: &str, use_index: usize) -> Option<&TypeBinding> {
        self.bindings
            .iter()
            .rev()
            .find(|binding| binding.name == name && binding.visible_at(use_index))
    }

    /// Resolves a declared function return type for a call expression.
    fn resolve_function_return(
        &self,
        tokens: TokenCursor<'_>,
        token_facts: &TypedTokenFacts,
        call: &FunctionCallRange,
    ) -> Option<BindingType> {
        let name = call.name.as_str();
        let mut matches = self
            .functions
            .iter()
            .rev()
            .filter(|function| function.name == name)
            .filter(|function| function.parameters.len() == call.arguments.len())
            .filter(|function| {
                function.parameters.iter().zip(call.arguments.iter()).all(
                    |(parameter, argument)| match parameter {
                        BindingType::Scalar => VectorExpressionAnalyzer {
                            facts: self,
                            token_facts,
                        }
                        .argument_is_scalar_like(tokens, argument),
                        BindingType::Vector(width) => {
                            VectorExpressionAnalyzer {
                                facts: self,
                                token_facts,
                            }
                            .argument_vector_width(tokens, argument)
                                == Some(*width)
                        }
                        BindingType::Blocker | BindingType::Sampler2D => false,
                    },
                )
            })
            .map(|function| function.ty);
        let first = matches.next()?;
        matches.all(|ty| ty == first).then_some(first)
    }
}

impl From<&ScopedDeclarationFacts> for Vec<TypeBinding> {
    fn from(facts: &ScopedDeclarationFacts) -> Self {
        facts
            .declarations()
            .iter()
            .map(|declaration| TypeBinding {
                name: SmolStr::new(declaration.name()),
                ty: BindingType::classify(declaration.ty()),
                component: ComponentKind::classify(declaration.ty()),
                visible_start: declaration.visible_start(),
                scope_end: declaration.scope_end(),
            })
            .collect()
    }
}

/// One scalar or vector binding.
#[derive(Clone)]
pub(super) struct TypeBinding {
    /// Variable name.
    pub name: SmolStr,
    /// Declared scalar or vector type.
    pub ty: BindingType,
    /// Kind of the declared type's components.
    pub component: ComponentKind,
    /// First token where this binding is visible.
    pub visible_start: usize,
    /// First token outside this binding's lexical scope.
    pub scope_end: usize,
}
/// Function return type fact.
#[derive(Clone)]
pub(super) struct FunctionTypeBinding {
    /// Function name.
    pub name: SmolStr,
    /// Declared return shape.
    pub ty: BindingType,
    /// Declared parameter shapes in source order.
    pub parameters: Vec<BindingType>,
}
/// Function return type facts collected from signatures and prototypes.
#[derive(Default)]
pub(super) struct FunctionTypeBindings {
    /// Function bindings in source order.
    pub items: Vec<FunctionTypeBinding>,
}

impl FunctionTypeBindings {
    /// Classifies tokenizer-owned function signature facts.
    pub(super) fn collect(&mut self, signatures: &[FunctionSignatureFact]) {
        self.items.extend(signatures.iter().filter_map(|fact| {
            let ty = BindingType::classify(fact.return_type().as_str());
            if matches!(ty, BindingType::Blocker | BindingType::Sampler2D) {
                return None;
            }
            Some(FunctionTypeBinding {
                name: fact.name().clone(),
                ty,
                parameters: fact
                    .parameters()
                    .iter()
                    .map(|parameter| BindingType::classify(parameter.ty().as_str()))
                    .collect(),
            })
        }));
    }
}

impl TypeBinding {
    /// Returns whether this binding is visible at `use_index`.
    pub(super) const fn visible_at(&self, use_index: usize) -> bool {
        self.visible_start <= use_index && use_index < self.scope_end
    }
}
/// Scalar/vector shape for one visible declaration.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum BindingType {
    /// Scalar or otherwise non-vector local type.
    Scalar,
    /// Vector declaration width.
    Vector(VectorWidth),
    /// A non-comparison 2D sampler whose sampled value has four components.
    Sampler2D,
    /// Aggregate declaration that shadows an outer scalar/vector name.
    Blocker,
}

/// Component kind of a declared scalar or vector type.
///
/// [`BindingType`] only tells shapes apart; builtins such as `clamp` exist
/// for both float and integer components, and which one a call selects
/// depends on this.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum ComponentKind {
    /// `float`, `vecN` and their legacy spellings.
    Float,
    /// `int` and `ivecN`.
    Int,
    /// `uint` and `uvecN`.
    Uint,
    /// Booleans, matrices, structs and anything else.
    Other,
}

impl ComponentKind {
    /// Classifies a declaration type spelling by component kind.
    pub(super) fn classify(name: &str) -> Self {
        match LegacyTypeName::new(name).glsl().as_bytes() {
            b"float" | b"vec2" | b"vec3" | b"vec4" => Self::Float,
            b"int" | b"ivec2" | b"ivec3" | b"ivec4" => Self::Int,
            b"uint" | b"uvec2" | b"uvec3" | b"uvec4" => Self::Uint,
            _ => Self::Other,
        }
    }
}

impl BindingType {
    /// Classifies declaration type spelling into scalar or vector shape.
    pub(super) fn classify(name: &str) -> Self {
        if let Some(width) = VectorWidth::classify_constructor(name) {
            Self::Vector(width)
        } else if matches!(
            name.as_bytes(),
            b"bool" | b"int" | b"uint" | b"float" | b"float1"
        ) {
            Self::Scalar
        } else if name == "sampler2D" {
            Self::Sampler2D
        } else {
            Self::Blocker
        }
    }
}

impl ScalarExpressionFacts for VectorTypeBindings<'_> {
    fn visible_type(&self, name: &str, index: usize) -> Option<ScalarType> {
        let binding = self.visible(name, index)?;
        Some(match (binding.ty, binding.component) {
            (BindingType::Scalar, ComponentKind::Float) => ScalarType::Float,
            (BindingType::Scalar, ComponentKind::Int) => ScalarType::Int,
            (BindingType::Scalar, ComponentKind::Uint) => ScalarType::Uint,
            (BindingType::Scalar, ComponentKind::Other) => ScalarType::Bool,
            (BindingType::Vector(_), _) => ScalarType::FloatVector,
            (BindingType::Sampler2D | BindingType::Blocker, _) => ScalarType::NonFloatAggregate,
        })
    }

    fn float_lvalue(&self, lvalue: &Lvalue) -> bool {
        match ScalarExpressionFacts::visible_type(self, lvalue.base.as_str(), lvalue.end) {
            Some(ScalarType::Float) => !lvalue.has_member,
            Some(ScalarType::FloatVector) => lvalue.has_member,
            _ => false,
        }
    }
}

impl VectorExpressionFacts for VectorTypeBindings<'_> {
    fn expression_type(&self, name: &str, index: usize) -> Option<VectorExpressionType> {
        match self.lookup(name, index) {
            Some(BindingType::Scalar) => Some(VectorExpressionType::Scalar),
            Some(BindingType::Vector(width)) => Some(VectorExpressionType::Vector(width)),
            Some(BindingType::Blocker | BindingType::Sampler2D) => Some(VectorExpressionType::Blocker),
            None => None,
        }
    }

    fn function_return(
        &self,
        tokens: TokenCursor<'_>,
        token_facts: &TypedTokenFacts,
        call: &FunctionCallRange,
    ) -> Option<VectorExpressionType> {
        if !self.functions.iter().any(|function| function.name == call.name)
            && super::super::texture_sampling::TextureSamplingFunction::classify_name(&call.name).is_some()
            && let Some(sampler) = call.arguments.iter().next()
            && sampler.is_single_token()
            && let Some(name) = tokens[sampler.start()].kind().identifier_text()
            && self.lookup(name, sampler.start()) == Some(BindingType::Sampler2D)
        {
            return Some(VectorExpressionType::Vector(VectorWidth::Four));
        }
        match self.resolve_function_return(tokens, token_facts, call)? {
            BindingType::Scalar => Some(VectorExpressionType::Scalar),
            BindingType::Vector(width) => Some(VectorExpressionType::Vector(width)),
            BindingType::Blocker | BindingType::Sampler2D => Some(VectorExpressionType::Blocker),
        }
    }
}
