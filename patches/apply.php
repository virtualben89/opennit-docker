<?php
// Lokale Fixes für Upstream-Fehler, die noch nicht in OpenNIT behoben sind.
// Jeder Fix ersetzt genau eine bekannte Stelle. Findet er sie nicht (Upstream hat den
// Code geändert oder den Fehler selbst behoben), gibt er nur einen Hinweis aus und der
// Build läuft weiter – dann den Fix prüfen und ggf. entfernen.
// Aufruf: php apply.php <APP_DIR>

$app = rtrim($argv[1] ?? '/var/www/opennit', '/');

$fixes = [
    [
        // MCP "ping" antwortet mit result = stdClass ({}); ausgang() greift darauf per
        // Array-Zugriff zu -> "Cannot use object of type stdClass as array" -> HTTP 500
        // nach bereits gesendeter Antwort. Clients mit Keepalive-Ping (z. B. Hermes)
        // verwerfen die Verbindung dann immer wieder.
        'id'   => 'mcp-ping-stdclass',
        'file' => 'src/Controllers/McpController.php',
        'old'  => "private static function ausgang(int \$status, array \$rumpf): string\n    {\n",
        'new'  => "private static function ausgang(int \$status, array \$rumpf): string\n    {\n"
                . "        // opennit-docker fix mcp-ping-stdclass: Objekte (z. B. leeres result von ping) als Arrays lesen\n"
                . "        \$rumpf = json_decode(json_encode(\$rumpf), true) ?? [];\n",
    ],
];

$fehler = 0;
foreach ($fixes as $f) {
    $pfad = "$app/{$f['file']}";
    $code = @file_get_contents($pfad);
    if ($code === false) {
        echo "patch {$f['id']}: {$f['file']} fehlt – übersprungen\n";
        continue;
    }
    if (str_contains($code, "opennit-docker fix {$f['id']}")) {
        echo "patch {$f['id']}: schon angewendet\n";
        continue;
    }
    if (substr_count($code, $f['old']) !== 1) {
        echo "patch {$f['id']}: Stelle nicht (eindeutig) gefunden – Upstream geändert? Fix prüfen\n";
        continue;
    }
    file_put_contents($pfad, str_replace($f['old'], $f['new'], $code));
    exec('php -l ' . escapeshellarg($pfad) . ' 2>&1', $out, $rc);
    if ($rc !== 0) {
        echo "patch {$f['id']}: Syntaxfehler nach Patch\n" . implode("\n", $out) . "\n";
        $fehler++;
        continue;
    }
    echo "patch {$f['id']}: angewendet\n";
}
exit($fehler ? 1 : 0);
