"""The product index in Chroma. Synchronous client; call it through asyncio.to_thread."""
from dataclasses import dataclass

import chromadb


@dataclass(frozen=True)
class Hit:
    """One retrieved product and how far it sits from the question."""

    product_id: int
    name: str
    distance: float
    document: str


class ProductIndex:
    """Stores one embedding per product and finds the nearest ones to a question."""

    def __init__(self, host: str, port: int, collection: str) -> None:
        """Remember where Chroma lives; connect lazily so startup never blocks on it."""
        self._host = host
        self._port = port
        self._name = collection
        self._client: chromadb.ClientAPI | None = None

    def heartbeat(self) -> bool:
        """Return True if Chroma answers."""
        try:
            self._connect().heartbeat()
        except Exception:
            self._client = None
            return False
        return True

    def count(self) -> int:
        """Return how many products are indexed."""
        return self._collection().count()

    def replace_all(self, ids: list[int], names: list[str], documents: list[str],
                    embeddings: list[list[float]]) -> int:
        """Drop the collection and index exactly the given products."""
        client = self._connect()
        try:
            client.delete_collection(self._name)
        except Exception:
            # Chroma raises if the collection does not exist yet; nothing to delete is fine
            client.get_or_create_collection(self._name)
        collection = self._collection()
        if ids:
            collection.add(
                ids=[str(product_id) for product_id in ids],
                embeddings=embeddings,
                documents=documents,
                metadatas=[{"product_id": product_id, "name": name} for product_id, name in zip(ids, names)],
            )
        return collection.count()

    def query(self, embedding: list[float], k: int) -> list[Hit]:
        """Return up to k nearest products, closest first. Never empty while the index has rows."""
        result = self._collection().query(query_embeddings=[embedding], n_results=k)
        hits: list[Hit] = []
        for metadata, distance, document in zip(result["metadatas"][0], result["distances"][0],
                                                result["documents"][0]):
            hits.append(Hit(int(metadata["product_id"]), str(metadata["name"]), float(distance), document))
        return hits

    def _collection(self) -> chromadb.Collection:
        """Return the product collection, creating it with cosine distance if needed."""
        return self._connect().get_or_create_collection(
            self._name, metadata={"hnsw:space": "cosine"}, embedding_function=None)

    def _connect(self) -> chromadb.ClientAPI:
        """Open the HTTP client on first use."""
        if self._client is None:
            self._client = chromadb.HttpClient(host=self._host, port=self._port)
        return self._client
