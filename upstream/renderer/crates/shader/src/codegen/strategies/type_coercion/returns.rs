use super::{Fixup, SourceSpan, StrategyContext, types::VectorTypeBindings};
use crate::{
    codegen::{
        ExpressionReplacement,
        expressions::analysis::{VectorExpressionAnalyzer, VectorWidth},
    },
    syntax::{CallArgument, ShaderModule},
    tokenizer::{KeywordType, TokenCursor, TypedTokenFacts},
};

/// Returned values converted to their function's declared return type.
///
/// The permissive path converts a returned value the way it converts an
/// assigned one, so `vec3 drawScene() { vec4 col; ...; return col; }` keeps
/// the leading components. A strict frontend rejects the mismatched return,
/// and the effect with it.
#[derive(Default)]
pub(super) struct ReturnConversions {
    /// Conversions in source order.
    pub items: Vec<ReturnConversion>,
}

impl ReturnConversions {
    /// Scans every function body for returns whose value shape differs from
    /// the declared return type.
    pub(super) fn collect(
        &mut self,
        module: &ShaderModule<'_>,
        tokens: TokenCursor<'_>,
        token_facts: &TypedTokenFacts,
        facts: &VectorTypeBindings<'_>,
    ) {
        let analyzer = VectorExpressionAnalyzer { facts, token_facts };
        for function in module.functions().iter() {
            let declared = match function.return_type() {
                "float" | "float1" => None,
                ty => match VectorWidth::classify_constructor(ty) {
                    Some(width) => Some(width),
                    None => continue,
                },
            };
            let Some(body) = tokens
                .contained_byte_range(function.body_span().start(), function.body_span().end())
            else {
                continue;
            };
            for index in body.start()..body.end() {
                if !tokens[index].kind().is_keyword(KeywordType::Return) {
                    continue;
                }
                let Some(value) = tokens.next_non_comment(index + 1) else {
                    continue;
                };
                let Some(semicolon) = tokens.top_level_semicolon_from(value) else {
                    continue;
                };
                let Some(argument) = CallArgument::trim_from_bounds(tokens, value, semicolon)
                else {
                    continue;
                };
                let Ok(span) = SourceSpan::new(
                    tokens[argument.start()].span().start(),
                    tokens[argument.end()].span().end(),
                ) else {
                    continue;
                };
                let width = analyzer.argument_vector_width(tokens, argument);
                let kind = match (declared, width) {
                    (Some(declared), Some(width)) if width > declared => {
                        ReturnConversionKind::Narrow(declared.component_swizzle())
                    }
                    (Some(declared), None)
                        if analyzer.argument_is_scalar_like(tokens, argument) =>
                    {
                        ReturnConversionKind::Broadcast(declared)
                    }
                    (None, Some(_width)) => ReturnConversionKind::Narrow(".x"),
                    _ => continue,
                };
                self.items.push(ReturnConversion {
                    span,
                    grouped: argument.is_single_token(),
                    kind,
                });
            }
        }
    }
}

/// One returned value that needs converting.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct ReturnConversion {
    /// Returned expression span.
    span: SourceSpan,
    /// Whether the expression is one token, so a swizzle can follow it as is.
    grouped: bool,
    /// Conversion to apply.
    kind: ReturnConversionKind,
}

/// Conversion applied to a returned value.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ReturnConversionKind {
    /// Keep the leading components with this swizzle.
    Narrow(&'static str),
    /// Broadcast a scalar to this vector width.
    Broadcast(VectorWidth),
}

impl ReturnConversion {
    /// Emits the conversion around the returned expression, preserving nested
    /// expression fixups.
    pub(super) fn emit(self, context: &mut StrategyContext<'_, '_, '_>) {
        let replacement = match self.kind {
            ReturnConversionKind::Narrow(swizzle) if self.grouped => ExpressionReplacement::new()
                .with_source(self.span)
                .with_text(swizzle),
            ReturnConversionKind::Narrow(swizzle) => ExpressionReplacement::new()
                .with_text("(")
                .with_source(self.span)
                .with_text(format!("){swizzle}")),
            ReturnConversionKind::Broadcast(width) => ExpressionReplacement::new()
                .with_text(format!("{}(", width.constructor()))
                .with_source(self.span)
                .with_text(")"),
        };
        context
            .context()
            .fixups
            .push(Fixup::replace(self.span, replacement));
    }
}
