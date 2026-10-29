#include <stddef.h>
#include <stdio.h>
#include <libxml/parser.h>
#include <libxml/entities.h>
#include <libxml/tree.h>
/* Metadata only: no parsing, external resources or library function calls. */
int main(void) {
    printf("xmlEntity=%zu\n", sizeof(xmlEntity));
    printf("xmlParserInput=%zu\n", sizeof(xmlParserInput));
    printf("xmlParserCtxt=%zu\n", sizeof(xmlParserCtxt));
    printf("xmlNode=%zu\n", sizeof(xmlNode));
    printf("xmlDoc=%zu\n", sizeof(xmlDoc));
    printf("xmlSAXHandler=%zu\n", sizeof(xmlSAXHandler));
    printf("xmlEntity.content=%zu\n", offsetof(xmlEntity, content));
    printf("xmlEntity.length=%zu\n", offsetof(xmlEntity, length));
    printf("xmlParserInput.cur=%zu\n", offsetof(xmlParserInput, cur));
    printf("xmlParserInput.end=%zu\n", offsetof(xmlParserInput, end));
    printf("xmlParserCtxt.inputNr=%zu\n", offsetof(xmlParserCtxt, inputNr));
    return 0;
}
