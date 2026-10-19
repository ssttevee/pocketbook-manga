import java.nio.file.*;
import java.security.KeyStore;
import java.security.cert.CertificateFactory;
public class BuildTrustStore {
  public static void main(String[] args) throws Exception {
    var store = KeyStore.getInstance("JKS");
    store.load(null, "changeit".toCharArray());
    var factory = CertificateFactory.getInstance("X.509");
    try (var files = Files.walk(Path.of(args[0]))) {
      for (var file : files.filter(p -> p.toString().endsWith(".crt")).sorted().toList())
        try (var input = Files.newInputStream(file)) {
          store.setCertificateEntry(file.getFileName().toString(), factory.generateCertificate(input));
        }
    }
    try (var output = Files.newOutputStream(Path.of(args[1]))) { store.store(output, "changeit".toCharArray()); }
    System.out.println("Bundled " + store.size() + " public certificate authorities");
  }
}
