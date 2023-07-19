import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Base64;

public class JWTEncryptor {
    
    public static void main(String[] args) {
        String jwtToken = "your_jwt_token_here";
        String secretKey = "your_secret_key_here";
        
        String encryptedToken = encryptJWT(jwtToken, secretKey);
        System.out.println("Encrypted JWT token: " + encryptedToken);
    }
    
    public static String encryptJWT(String jwtToken, String secretKey) {
        try {
            byte[] secretKeyBytes = secretKey.getBytes(StandardCharsets.UTF_8);
            
            MessageDigest messageDigest = MessageDigest.getInstance("SHA-256");
            messageDigest.update(secretKeyBytes);
            byte[] hashedBytes = messageDigest.digest();
            
            String base64Encoded = Base64.getEncoder().encodeToString(hashedBytes);
            
            return base64Encoded;
        } catch (NoSuchAlgorithmException e) {
            e.printStackTrace();
        }
        
        return null;
    }
}