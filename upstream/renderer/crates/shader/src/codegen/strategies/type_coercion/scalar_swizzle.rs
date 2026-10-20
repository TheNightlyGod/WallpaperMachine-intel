//! Scalar component selections accepted by the legacy shader dialect.

use super::StrategyContext;
use crate::{
    ShaderResult, SourceSpan,
    codegen::{
        Fixup, ScopedDeclarationFacts,
        expressions::analysis::{ScalarSwizzleField, ScalarType},
    },
    tokenizer::{ExpressionShape, LiteralValue, TokenCursor, TokenIndexRange, TypedToken},
};

/// Broadcasts known scalar reads without changing actual vector swizzles.
pub(super) fn emit(
    context: &mut StrategyContext<'_, '_, '_>,
    tokens: TokenCursor<'_>,
    facts: &ScopedDeclarationFacts,
) -> ShaderResult<()> {
    for field_index in 0..tokens.len() {
        let TypedToken::Identifier(field) = tokens[field_index].kind() else {
            continue;
        };
        let Some(field) = ScalarSwizzleField::parse(field.as_str()) else {
            continue;
        };
        let Some(dot) = tokens.previous_non_comment(field_index) else {
            continue;
        };
        if !tokens[dot].kind().is_member_access_operator() {
            continue;
        }
        let Some(base_end) = tokens.previous_non_comment(dot) else {
            continue;
        };
        let Some(base_start) = operand_start(tokens, base_end) else {
            continue;
        };
        let Some(ty) = scalar_type(
            tokens,
            facts,
            TokenIndexRange::from_inclusive(base_start, base_end),
        ) else {
            continue;
        };
        let suffix = if field.component_count == 1 {
            ""
        } else {
            let prefix = match ty {
                ScalarType::Float => "vec",
                ScalarType::Int => "ivec",
                ScalarType::Uint => "uvec",
                ScalarType::Bool => "bvec",
                ScalarType::FloatVector | ScalarType::NonFloatAggregate => continue,
            };
            context.context().fixups.push(Fixup::insert(
                tokens[base_start].span().start_point(),
                format!("{prefix}{}(", field.component_count),
            ));
            ")"
        };
        context.context().fixups.push(Fixup::replace(
            SourceSpan::new(tokens[dot].span().start(), tokens[field_index].span().end())?,
            suffix,
        ));
    }
    Ok(())
}

/// Finds the postfix operand rather than consuming a preceding binary operator.
fn operand_start(tokens: TokenCursor<'_>, end: usize) -> Option<usize> {
    let start = if tokens[end].kind().is_right_paren() {
        let open = tokens.enclosing_left_paren_before(end)?;
        match tokens.previous_non_comment(open) {
            Some(name)
                if matches!(tokens[name].kind(), TypedToken::Identifier(_) | TypedToken::TypeMark(_)) =>
            {
                name
            }
            _ => open,
        }
    } else if matches!(tokens[end].kind(), TypedToken::Identifier(_) | TypedToken::Literal(_)) {
        end
    } else {
        return None;
    };
    // A field's spelling is not a reference to a same-named scalar variable.
    if let Some(dot) = tokens.previous_non_comment(start)
        && tokens[dot].kind().is_member_access_operator()
    {
        return operand_start(tokens, tokens.previous_non_comment(dot)?);
    }
    Some(start)
}

/// Requires scalar evidence for every operand, including lexical shadowing.
fn scalar_type(
    tokens: TokenCursor<'_>,
    facts: &ScopedDeclarationFacts,
    range: TokenIndexRange,
) -> Option<ScalarType> {
    match ExpressionShape::classify(tokens, range) {
        ExpressionShape::Parenthesized(inner) => scalar_type(tokens, facts, inner),
        ExpressionShape::ScalarAtom => match tokens[range.start()].kind() {
            TypedToken::Identifier(name) if matches!(name.as_str(), "true" | "false") => {
                Some(ScalarType::Bool)
            }
            TypedToken::Identifier(name) => facts
                .declarations()
                .iter()
                .rev()
                .find(|declaration| {
                    declaration.name() == name.as_str()
                        && declaration.visible_start() <= range.start()
                        && range.start() < declaration.scope_end()
                })
                .and_then(|declaration| declared_scalar_type(declaration.ty())),
            TypedToken::Literal(LiteralValue::Number(text)) => {
                ScalarType::classify_numeric_literal(text)
            }
            _ => None,
        },
        ExpressionShape::Binary { left, right, .. } => {
            let left = scalar_type(tokens, facts, left)?;
            let right = scalar_type(tokens, facts, right)?;
            match (left, right) {
                (ScalarType::Float, ScalarType::Float | ScalarType::Int | ScalarType::Uint)
                | (ScalarType::Int | ScalarType::Uint, ScalarType::Float) => Some(ScalarType::Float),
                (ScalarType::Int, ScalarType::Int) => Some(ScalarType::Int),
                (ScalarType::Uint, ScalarType::Uint) => Some(ScalarType::Uint),
                _ => None,
            }
        }
        ExpressionShape::FunctionCall { name, .. } => declared_scalar_type(name.as_str()),
        ExpressionShape::Member { base, field }
            if matches!(field.as_str(), "x" | "r" | "s") =>
        {
            scalar_type(tokens, facts, base)
        }
        ExpressionShape::Unknown
        | ExpressionShape::Member { .. }
        | ExpressionShape::Index { .. } => None,
    }
}

/// Keeps integer and boolean splats in their original component domain.
fn declared_scalar_type(name: &str) -> Option<ScalarType> {
    match name {
        "float" | "float1" => Some(ScalarType::Float),
        "int" => Some(ScalarType::Int),
        "uint" => Some(ScalarType::Uint),
        "bool" => Some(ScalarType::Bool),
        _ => None,
    }
}
