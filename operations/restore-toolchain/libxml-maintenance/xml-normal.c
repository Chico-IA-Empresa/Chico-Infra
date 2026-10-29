#define _GNU_SOURCE
#include <dlfcn.h>
#include <string.h>
#include <libxml/parser.h>
#include <libxml/xpath.h>
#include <libxml/c14n.h>
/* One bounded, well-formed ordinary document; no DTD, entity declarations,
 * external references, malformed inputs, CVE reproductions or fuzzing. */
int main(void) {
    Dl_info loaded;
    const char *prefix = "/opt/chico-libxml-candidate/lib/";
    if (!dladdr((void *)xmlReadMemory, &loaded) || !loaded.dli_fname ||
        strncmp(loaded.dli_fname, prefix, strlen(prefix)) != 0) return 5;
    const char *text = "<root><item id=\"1\">alpha</item><item id=\"2\">beta</item></root>";
    xmlDocPtr doc = xmlReadMemory(text, (int)strlen(text), "normal.xml", NULL, XML_PARSE_NONET);
    if (!doc) return 1;
    xmlXPathContextPtr context = xmlXPathNewContext(doc);
    if (!context) return 2;
    xmlXPathObjectPtr result = xmlXPathEvalExpression(BAD_CAST "count(/root/item)", context);
    if (!result || result->type != XPATH_NUMBER || result->floatval != 2.0) return 3;
    xmlChar *canonical = NULL;
    int size = xmlC14NDocDumpMemory(doc, NULL, XML_C14N_1_0, NULL, 0, &canonical);
    int okay = size == (int)strlen(text) && canonical && strcmp((char *)canonical, text) == 0;
    xmlFree(canonical);
    xmlXPathFreeObject(result);
    xmlXPathFreeContext(context);
    xmlFreeDoc(doc);
    xmlCleanupParser();
    return okay ? 0 : 4;
}
