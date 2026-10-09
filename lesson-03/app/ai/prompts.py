"""Prompt text lives in one place and carries a version, so every answer can name the prompt that made it."""
from app.ai.vectors import Hit

PROMPT_VERSION = "shop-assistant-v1"

TEMPLATE = """You are the shop assistant for QATP Store.
Answer the customer's question using only the products listed below.
If none of them fits, say that the store does not sell it.
Mention prices in dollars. Keep the answer under 80 words.

Products:
{context}

Customer question: {question}
Answer:"""


def product_document(name: str, description: str, price_cents: int, stock: int) -> str:
    """Render one product as the text that gets embedded and shown to the model."""
    return f"{name}: {description}. Price ${price_cents / 100:.2f}. {stock} in stock."


def build_prompt(question: str, hits: list[Hit]) -> str:
    """Fill the template with the retrieved products and the question."""
    context = "\n".join(f"- [{hit.product_id}] {hit.document}" for hit in hits)
    return TEMPLATE.format(context=context or "- (no products indexed)", question=question.strip())
