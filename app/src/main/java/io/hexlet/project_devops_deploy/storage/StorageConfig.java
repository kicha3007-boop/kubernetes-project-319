package io.hexlet.project_devops_deploy.storage;

import org.springframework.boot.autoconfigure.condition.ConditionalOnMissingBean;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.util.StringUtils;

@Configuration
@EnableConfigurationProperties(S3StorageProperties.class)
public class StorageConfig {

    @Bean
    @ConditionalOnMissingBean(ImageStorageService.class)
    public ImageStorageService imageStorageService(S3StorageProperties properties) {
        // В профиле prod переменные STORAGE_S3_* по умолчанию раскрываются в пустые строки,
        // поэтому проверяем наличие текста, а не только null: без S3 — локальное хранилище.
        if (StringUtils.hasText(properties.bucket())
                && StringUtils.hasText(properties.region())
                && StringUtils.hasText(properties.accessKey())
                && StringUtils.hasText(properties.secretKey())) {
            return new S3ImageStorageService(properties);
        }
        return new LocalImageStorageService();
    }
}
