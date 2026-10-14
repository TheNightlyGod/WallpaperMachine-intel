use super::{
    expr::{BoolExpression, BoolExpressionInput},
    statements::StatementFixupInput,
    symbols::SymbolFacts,
};
use crate::{
    SourceSpan,
    codegen::{ExpressionReplacement, Fixup, expressions::analysis::Lvalue},
    tokenizer::{
        AssignmentOperator, OperatorType as ShaderOp, TokenCursor, TypedToken, TypedTokenFacts,
    },
};

/// Float initialized from a boolean expression.
pub(super) struct BoolFloatInitializer<'statement, 'src> {
    /// Statement being inspected.
    pub statement: StatementFixupInput<'statement>,
    /// Known symbol facts.
    pub facts: &'statement SymbolFacts<'src>,
    /// Shared tokenizer declaration facts.
    pub token_facts: &'statement TypedTokenFacts,
}

impl BoolFloatInitializer<'_, '_> {
    /// Emits all boolean-expression initializer coercions in this declaration.
    pub(super) fn fixups(self, tokens: TokenCursor<'_>) -> Vec<Fixup> {
        let declarations =
            self.statement
                .declaration_declarators(tokens, self.token_facts, "float");
        if declarations.is_empty() {
            return Vec::new();
        }
        let mut fixups = Vec::new();
        for declaration in declarations {
            let Some(initializer) = declaration.initializer(tokens) else {
                continue;
            };
            if BoolExpression::classify(
                BoolExpressionInput {
                    start: initializer.start(),
                    end: initializer.end(),
                    facts: self.facts,
                    token_facts: self.token_facts,
                },
                tokens,
            )
            .is_err()
            {
                continue;
            }
            let rhs_span = initializer.span();
            let replacement = ExpressionReplacement::new()
                .with_text("((")
                .with_source(rhs_span)
                .with_text(") ? 1.0 : 0.0)");
            fixups.push(Fixup::replace(rhs_span, replacement));
        }
        fixups
    }
}

/// Boolean stored into a float lvalue by an assignment.
///
/// The permissive path converts the comparison in `x += a < b;` or
/// `x = flag;` to `1.0`/`0.0`, as it does for an initializer.
#[derive(Clone, Copy)]
pub(super) struct FloatBoolAssignment<'statement, 'src> {
    /// Statement being inspected.
    pub statement: StatementFixupInput<'statement>,
    /// Known symbol facts.
    pub facts: &'statement SymbolFacts<'src>,
    /// Shared tokenizer declaration facts.
    pub token_facts: &'statement TypedTokenFacts,
}

impl FloatBoolAssignment<'_, '_> {
    /// Builds a fixup for a boolean right-hand side stored into a float.
    pub(super) fn build_fixup(self, tokens: TokenCursor<'_>) -> Result<Fixup, ()> {
        let search = tokens;
        let semicolon = self.statement.semicolon(tokens).ok_or(())?;
        for index in self.statement.start()..semicolon {
            if !matches!(
                tokens[index].kind(),
                TypedToken::Operator(ShaderOp::Assignment(
                    AssignmentOperator::Assign
                        | AssignmentOperator::AddAssign
                        | AssignmentOperator::SubtractAssign
                        | AssignmentOperator::MultiplyAssign
                        | AssignmentOperator::DivideAssign
                ))
            ) {
                continue;
            }
            let lhs_end = search.previous_non_comment(index).ok_or(())?;
            // A declaration initializer is converted by `BoolFloatInitializer`.
            if self
                .token_facts
                .declarations()
                .iter()
                .any(|declaration| declaration.name_index() == lhs_end)
            {
                continue;
            }
            let lhs = Lvalue::ending_at(tokens, lhs_end).ok_or(())?;
            if !self.facts.float_lvalue(&lhs) {
                continue;
            }
            let rhs_start = search.next_non_comment(index + 1).ok_or(())?;
            let rhs_end = search.previous_non_comment(semicolon).ok_or(())?;
            if rhs_start > rhs_end
                || tokens[rhs_start..rhs_end + 1]
                    .iter()
                    .any(|token| token.kind().is_assignment_operator())
                || BoolExpression::classify(
                    BoolExpressionInput {
                        start: rhs_start,
                        end: rhs_end,
                        facts: self.facts,
                        token_facts: self.token_facts,
                    },
                    tokens,
                )
                .is_err()
            {
                continue;
            }
            let rhs = SourceSpan::new(
                tokens[rhs_start].span().start(),
                tokens[rhs_end].span().end(),
            )
            .map_err(|_error| ())?;
            let replacement = if rhs_start == rhs_end {
                ExpressionReplacement::new()
                    .with_text("(")
                    .with_source(rhs)
                    .with_text(" ? 1.0 : 0.0)")
            } else {
                ExpressionReplacement::new()
                    .with_text("((")
                    .with_source(rhs)
                    .with_text(") ? 1.0 : 0.0)")
            };
            return Ok(Fixup::replace(rhs, replacement));
        }
        Err(())
    }
}
