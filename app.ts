import { APIGatewayProxyEvent, APIGatewayProxyResult } from "aws-lambda";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import {
  DynamoDBDocumentClient,
  GetCommand,
  PutCommand,
  UpdateCommand,
} from "@aws-sdk/lib-dynamodb";

const client = new DynamoDBClient({})
const docClient = DynamoDBDocumentClient.from(client)
const tabeleName = "clientUrl"

const handler = async (event: APIGatewayProxyEvent) => {
    try {
        const httpMethod = event.httpMethod
        const path = event.path
        if (httpMethod === "POST" && path === "/shorten") {
            return  await createShortUrl(event)
        }
    } catch (error) {
        
    }
}

const createShortUrl = async (event:APIGatewayProxyEvent) => {
    try {
        
    } catch (error) {
        
    }
}