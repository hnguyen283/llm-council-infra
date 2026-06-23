import psycopg2
import sys

def main():
    print("Connecting to local knowledge_db...")
    try:
        conn = psycopg2.connect(
            host="localhost",
            port=5433,
            dbname="knowledge_db",
            user="llm_admin",
            password="local_admin_pw_change_me"
        )
        conn.autocommit = False
    except Exception as e:
        print(f"Connection failed: {e}")
        sys.exit(1)

    try:
        with conn.cursor() as cur:
            # 1. Ensure extensions and schema are fully set up
            print("Verifying base schema and extensions...")
            cur.execute("CREATE EXTENSION IF NOT EXISTS age;")
            cur.execute("CREATE EXTENSION IF NOT EXISTS vector;")
            cur.execute("CREATE SCHEMA IF NOT EXISTS graphrag AUTHORIZATION graphrag_app;")
            conn.commit()

            # 2. Check if graph exists and create if necessary
            cur.execute("SELECT 1 FROM ag_catalog.ag_graph WHERE name = 'research_graph';")
            if not cur.fetchone():
                print("Creating 'research_graph' graph...")
                cur.execute("SELECT ag_catalog.create_graph('research_graph');")
                conn.commit()

            # 3. Create labels
            print("Creating vertex and edge labels...")
            labels = ["Document", "Chunk", "Entity", "CanonicalEntity", "EntityAlias"]
            for label in labels:
                try:
                    cur.execute("SELECT ag_catalog.create_vlabel('research_graph', %s);", (label,))
                except Exception as le:
                    # Ignore if label already exists
                    conn.rollback()
                    
            try:
                cur.execute("SELECT ag_catalog.create_elabel('research_graph', 'RELATED_TO');")
            except Exception as le:
                conn.rollback()

            conn.commit()

            # Set search path
            cur.execute('SET search_path = ag_catalog, graphrag, public;')

            # 4. Create relational tables if not present
            print("Creating relational tables in graphrag schema...")
            cur.execute("""
                CREATE TABLE IF NOT EXISTS graphrag.documents (
                    id VARCHAR(64) PRIMARY KEY,
                    url TEXT NOT NULL,
                    domain VARCHAR(255),
                    title TEXT,
                    md5_hash VARCHAR(32) NOT NULL,
                    language VARCHAR(10) DEFAULT 'en',
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                );
            """)
            cur.execute("""
                CREATE TABLE IF NOT EXISTS graphrag.chunks (
                    id VARCHAR(128) PRIMARY KEY,
                    document_id VARCHAR(64) REFERENCES graphrag.documents(id) ON DELETE CASCADE,
                    text_segment TEXT NOT NULL,
                    embedding vector(384),
                    staging BOOLEAN DEFAULT TRUE,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                );
            """)
            conn.commit()

            # 5. Insert Relational Data
            print("Inserting relational rows...")
            doc_id = "doc_llm_council_arch"
            cur.execute("""
                INSERT INTO graphrag.documents (id, url, domain, title, md5_hash, language)
                VALUES (%s, 'https://welllifeapp.com/docs/architecture', 'welllifeapp.com', 'LLM Council Architecture Overview', 'md5hashxyz', 'en')
                ON CONFLICT (id) DO NOTHING;
            """, (doc_id,))

            cur.execute("""
                INSERT INTO graphrag.chunks (id, document_id, text_segment, staging)
                VALUES 
                ('chunk_1', %s, 'LLM Council is a research orchestrator that coordinates a panel of LLMs (Gemini, GPT, LocalAI) using a Spring Boot orchestrator service and Apache Kafka message broker.', FALSE),
                ('chunk_2', %s, 'Graph RAG adds structured retrieval context to user queries by storing documents, chunks, and entities in a PostgreSQL database with Apache AGE graph database and pgvector extensions.', FALSE)
                ON CONFLICT (id) DO NOTHING;
            """, (doc_id, doc_id))
            conn.commit()

            # 6. Clear existing graph data to avoid duplicates
            print("Clearing existing graph vertices and edges...")
            cur.execute("SELECT * FROM cypher('research_graph', $$ MATCH (n) DETACH DELETE n $$) as (v agtype);")
            conn.commit()

            # 7. Insert Graph Nodes
            print("Creating mock graph nodes...")
            
            # Create Document Node
            cur.execute("""
                SELECT * FROM cypher('research_graph', $$
                    CREATE (d:Document {id: "doc_llm_council_arch", title: "LLM Council Architecture Overview", url: "https://welllifeapp.com/docs/architecture", staging: false})
                $$) as (v agtype);
            """)

            # Create Chunk Nodes
            cur.execute("""
                SELECT * FROM cypher('research_graph', $$
                    CREATE (c1:Chunk {id: "chunk_1", document_id: "doc_llm_council_arch", text_segment: "LLM Council is a research orchestrator that coordinates a panel of LLMs (Gemini, GPT, LocalAI) using a Spring Boot orchestrator service and Apache Kafka message broker.", staging: false})
                $$) as (v agtype);
            """)
            cur.execute("""
                SELECT * FROM cypher('research_graph', $$
                    CREATE (c2:Chunk {id: "chunk_2", document_id: "doc_llm_council_arch", text_segment: "Graph RAG adds structured retrieval context to user queries by storing documents, chunks, and entities in a PostgreSQL database with Apache AGE graph database and pgvector extensions.", staging: false})
                $$) as (v agtype);
            """)

            # Create Canonical Entities
            entities = [
                ("LLM Council", "System", "The core research orchestrator system coordinating multi-agent panels."),
                ("Gemini Service", "Component", "The collection worker that performs web searches and gathers evidence."),
                ("GPT Service", "Component", "The reasoning worker that analyzes, debates, and judges collected evidence."),
                ("Local AI Service", "Component", "The offline planner that runs deepseek-r1 locally to generate query plans."),
                ("Orchestrator Service", "Component", "The Spring-based workflow engine executing the multi-stage research pipeline."),
                ("Graph RAG", "Feature", "The knowledge graph retrieval system utilizing Apache AGE and pgvector."),
                ("Apache AGE", "Database", "The extension enabling graph database capabilities inside PostgreSQL.")
            ]

            for idx, (name, ent_type, desc) in enumerate(entities):
                ent_id = f"ent_{idx+1}"
                # Safe escaping for description quotes
                safe_desc = desc.replace('"', '\\"')
                query = f"""
                    SELECT * FROM cypher('research_graph', $$
                        CREATE (e:CanonicalEntity {{id: "{ent_id}", name: "{name}", type: "{ent_type}", description: "{safe_desc}", staging: false}})
                    $$) as (v agtype);
                """
                cur.execute(query)

            conn.commit()

            # 8. Create Graph Relationships
            print("Creating mock graph relationships...")
            
            # Map chunk connections to Document
            cur.execute("""
                SELECT * FROM cypher('research_graph', $$
                    MATCH (d:Document {id: "doc_llm_council_arch"}), (c1:Chunk {id: "chunk_1"})
                    CREATE (c1)-[r:RELATED_TO {document_id: "doc_llm_council_arch", staging: false}]->(d)
                $$) as (v agtype);
            """)
            cur.execute("""
                SELECT * FROM cypher('research_graph', $$
                    MATCH (d:Document {id: "doc_llm_council_arch"}), (c2:Chunk {id: "chunk_2"})
                    CREATE (c2)-[r:RELATED_TO {document_id: "doc_llm_council_arch", staging: false}]->(d)
                $$) as (v agtype);
            """)

            # Map inter-entity connections
            relations = [
                ("Orchestrator Service", "LLM Council", "orchestrates"),
                ("Orchestrator Service", "Gemini Service", "triggers evidence collection"),
                ("Orchestrator Service", "GPT Service", "invokes for reasoning and judgment"),
                ("Orchestrator Service", "Local AI Service", "delegates planning workloads"),
                ("Orchestrator Service", "Graph RAG", "queries for context enhancement"),
                ("Graph RAG", "Apache AGE", "implemented on"),
                ("Gemini Service", "Graph RAG", "indexes collected evidence into")
            ]

            for src, dest, role in relations:
                query = f"""
                    SELECT * FROM cypher('research_graph', $$
                        MATCH (a:CanonicalEntity {{name: "{src}"}}), (b:CanonicalEntity {{name: "{dest}"}})
                        CREATE (a)-[r:RELATED_TO {{role: "{role}", document_id: "doc_llm_council_arch", staging: false}}]->(b)
                    $$) as (v agtype);
                """
                cur.execute(query)

            conn.commit()
            print("Mock graph and relational tables populated successfully!")

    except Exception as e:
        conn.rollback()
        print(f"Error during population: {e}")
        sys.exit(1)
    finally:
        conn.close()

if __name__ == "__main__":
    main()
