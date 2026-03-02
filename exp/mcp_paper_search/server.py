"""
MCP server exposing paper search tools for PostTrainBench experiments.
Tools: search_semantic_scholar, search_arxiv
Transport: stdio
"""

import json
import sys
import httpx
import xml.etree.ElementTree as ET
from mcp.server import Server
from mcp.server.stdio import stdio_server
from mcp import types

app = Server("paper-search")


@app.list_tools()
async def list_tools() -> list[types.Tool]:
    return [
        types.Tool(
            name="search_semantic_scholar",
            description=(
                "Search Semantic Scholar for academic papers. "
                "Returns title, authors, year, abstract, tldr, citation count, and URL."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": "Search query string",
                    },
                    "limit": {
                        "type": "integer",
                        "description": "Max number of results (default 5)",
                        "default": 5,
                    },
                },
                "required": ["query"],
            },
        ),
        types.Tool(
            name="search_arxiv",
            description=(
                "Search arXiv for academic papers. "
                "Returns title, authors, year, abstract, and arXiv URL."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": "Search query string",
                    },
                    "limit": {
                        "type": "integer",
                        "description": "Max number of results (default 5)",
                        "default": 5,
                    },
                },
                "required": ["query"],
            },
        ),
    ]


@app.call_tool()
async def call_tool(name: str, arguments: dict) -> list[types.TextContent]:
    if name == "search_semantic_scholar":
        result = await _search_semantic_scholar(
            query=arguments["query"],
            limit=arguments.get("limit", 5),
        )
    elif name == "search_arxiv":
        result = await _search_arxiv(
            query=arguments["query"],
            limit=arguments.get("limit", 5),
        )
    else:
        raise ValueError(f"Unknown tool: {name}")

    return [types.TextContent(type="text", text=result)]


async def _search_semantic_scholar(query: str, limit: int) -> str:
    url = "https://api.semanticscholar.org/graph/v1/paper/search"
    params = {
        "query": query,
        "limit": limit,
        "fields": "title,authors,year,abstract,tldr,citationCount,url",
    }

    async with httpx.AsyncClient(timeout=20.0) as client:
        resp = await client.get(url, params=params)
        resp.raise_for_status()
        data = resp.json()

    papers = data.get("data", [])
    if not papers:
        return "No results found on Semantic Scholar."

    lines = [f"Semantic Scholar results for: '{query}'\n"]
    for i, paper in enumerate(papers, 1):
        title = paper.get("title", "N/A")
        authors = ", ".join(a.get("name", "") for a in paper.get("authors", [])[:3])
        if len(paper.get("authors", [])) > 3:
            authors += " et al."
        year = paper.get("year", "N/A")
        citations = paper.get("citationCount", "N/A")
        abstract = (paper.get("abstract") or "")[:300]
        tldr = (paper.get("tldr") or {}).get("text", "")
        paper_url = paper.get("url", "")

        lines.append(f"{i}. {title} ({year})")
        lines.append(f"   Authors: {authors}")
        lines.append(f"   Citations: {citations}")
        if tldr:
            lines.append(f"   TL;DR: {tldr}")
        elif abstract:
            lines.append(f"   Abstract: {abstract}{'...' if len(paper.get('abstract', '')) > 300 else ''}")
        if paper_url:
            lines.append(f"   URL: {paper_url}")
        lines.append("")

    return "\n".join(lines)


async def _search_arxiv(query: str, limit: int) -> str:
    url = "https://export.arxiv.org/api/query"
    params = {
        "search_query": f"all:{query}",
        "start": 0,
        "max_results": limit,
        "sortBy": "relevance",
        "sortOrder": "descending",
    }

    async with httpx.AsyncClient(timeout=20.0) as client:
        resp = await client.get(url, params=params)
        resp.raise_for_status()
        xml_text = resp.text

    ns = {
        "atom": "http://www.w3.org/2005/Atom",
        "arxiv": "http://arxiv.org/schemas/atom",
    }
    root = ET.fromstring(xml_text)
    entries = root.findall("atom:entry", ns)

    if not entries:
        return "No results found on arXiv."

    lines = [f"arXiv results for: '{query}'\n"]
    for i, entry in enumerate(entries, 1):
        title = (entry.findtext("atom:title", "", ns) or "").replace("\n", " ").strip()
        authors = [a.findtext("atom:name", "", ns) for a in entry.findall("atom:author", ns)]
        author_str = ", ".join(authors[:3])
        if len(authors) > 3:
            author_str += " et al."
        published = (entry.findtext("atom:published", "", ns) or "")[:4]
        abstract = (entry.findtext("atom:summary", "", ns) or "").replace("\n", " ").strip()[:300]
        arxiv_url = ""
        for link in entry.findall("atom:link", ns):
            if link.get("type") == "text/html":
                arxiv_url = link.get("href", "")
                break

        lines.append(f"{i}. {title} ({published})")
        lines.append(f"   Authors: {author_str}")
        if abstract:
            lines.append(f"   Abstract: {abstract}{'...' if len((entry.findtext('atom:summary', '', ns) or '')) > 300 else ''}")
        if arxiv_url:
            lines.append(f"   URL: {arxiv_url}")
        lines.append("")

    return "\n".join(lines)


async def main():
    async with stdio_server() as (read_stream, write_stream):
        await app.run(read_stream, write_stream, app.create_initialization_options())


if __name__ == "__main__":
    import asyncio
    asyncio.run(main())
