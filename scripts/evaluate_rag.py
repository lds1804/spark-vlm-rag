import os
from ragas import evaluate
from ragas.metrics import faithfulness, answer_relevancy, context_precision
from datasets import Dataset
from llama_index.core import VectorStoreIndex, StorageContext
from llama_index.vector_stores.lancedb import LanceDBVectorStore
from llama_index.llms.groq import Groq
import lancedb

# Configuration
LANCEDB_URI = os.getenv("LANCEDB_URI")
GROQ_API_KEY = os.getenv("GROQ_API_KEY")

class RagasEvaluator:
    def __init__(self):
        self.llm = Groq(model="llama3-70b-8192", api_key=GROQ_API_KEY)
        self.db = lancedb.connect(LANCEDB_URI)
        self.table = self.db.open_table("chunks")
        
        # Setup LlamaIndex for retrieval
        self.vector_store = LanceDBVectorStore(uri=LANCEDB_URI, table_name="chunks")
        self.index = VectorStoreIndex.from_vector_store(self.vector_store)
        self.query_engine = self.index.as_query_engine()

    def run_eval(self, test_questions):
        data = {
            "question": [],
            "contexts": [],
            "answer": [],
            "ground_truth": [] # Optional, can be empty for unsupervised metrics
        }

        for q in test_questions:
            # 1. Retrieve & Generate
            response = self.query_engine.query(q)
            
            # 2. Collect for Ragas
            data["question"].append(q)
            data["answer"].append(str(response))
            data["contexts"].append([n.get_content() for n in response.source_nodes])
            data["ground_truth"].append("") # Add if known

        # 3. Convert to Dataset
        dataset = Dataset.from_dict(data)

        # 4. Run Evaluation
        # Note: In a real portfolio, use Groq via LangChain as the 'critic' for Ragas
        # to demonstrate cross-framework expertise.
        result = evaluate(
            dataset,
            metrics=[faithfulness, answer_relevancy, context_precision],
        )

        return result

if __name__ == "__main__":
    evaluator = RagasEvaluator()
    questions = [
        "What are the main symptoms of COVID-19 according to the research?",
        "How many chunks are in this dataset?",
        "What is the impact of remdesivir on patient recovery time?"
    ]
    results = evaluator.run_eval(questions)
    print("\n--- RAGAS RESULTS ---")
    print(results)
