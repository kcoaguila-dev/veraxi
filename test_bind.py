from langchain_openai import ChatOpenAI
llm = ChatOpenAI(model="gpt-4o", openai_api_key="sk-dummy")
bound = llm.bind_tools([])
print(bound.kwargs)
